//! Controle de taxa de bits de quem transmite.
//!
//! O servidor confirma cada frame, então dá pra medir o atraso que o upload
//! está acumulando de ponta a ponta (fila, kernel, túnel, rede) — mesmo quando
//! um túnel com buffer enorme esconde o congestionamento do TCP:
//!
//!   - atraso começando a crescer (> 100 ms): desce 7%, sem pular quadro;
//!   - atrasado de verdade (> 250 ms): pula quadros (não empilha) e, se não
//!     for só um soluço, desce 25%;
//!   - atraso zerado e 2 s sem problema: sobe rápido até 90% do "teto" (a
//!     taxa no começo do último episódio de congestionamento; os cortes
//!     dentro dele não rebaixam o teto), segura aí e, depois de 10 s sem
//!     problema, sonda devagar (+2%/s). Depois de 20 s sem problema, esquece
//!     o teto (o link pode ter melhorado). Medido no simlink.zig: com o teto
//!     rebaixado a cada corte e 15/30 s, um link de 3 Mbit/s rendia 2,5 e a
//!     volta pra 10 Mbit/s levava 16 s; agora 2,97 e 11 s.
//!   - soluço (o atraso passou do limite e voltou ao normal em até 0,5 s: o
//!     PC travou um instante com um jogo pesado, o Wi-Fi segurou uma rajada):
//!     não era a nossa taxa enchendo uma fila, então desfaz os cortes e o
//!     teto. Antes (3.10.2), cada soluço abria um episódio com o teto na taxa
//!     já cortada e a subida rápida ia só até 90% dele: com um soluço de
//!     150 ms a cada 4 s, 16,6 Mbit/s viravam 0,2 em 4 min, com o link sobrando.
//!
//! Espectador que não dá conta também pede menos (aviso do servidor com um
//! piso): -20% a cada 2 s no máximo, até o piso pedido, e a taxa não sobe por
//! 12 s (o tempo de ele recomeçar de um IDR e mostrar se agora dá conta).
const std = @import("std");
/// Calma (sem congestionar nem aviso de espectador) antes de sondar acima do
/// teto, e antes de esquecer o teto.
const PROBE_AFTER: u64 = 10_000_000;
const PROBE_FORGET: u64 = 20_000_000;
/// Episódio que acaba (atraso de volta abaixo de ramp_excess_us) até esse
/// tempo depois de começar é soluço. Fila de verdade demora mais: depois de
/// um corte de 7% ela escoa a no máximo 7% da velocidade do link, ~0,6 s só
/// pra ir de 100 a 60 ms.
const BLIP: u64 = 500_000;

pub const RateControl = struct {
    target: u32 = 0,
    bps: u32 = 0,
    last_congestion_us: u64 = 0,
    congested_since_us: u64 = 0, // 0 = sem congestionamento agora
    repeated: bool = false, // o congestionamento atual veio logo depois de outro
    last_adjust_us: u64 = 0,
    last_slow_us: u64 = 0,
    last_slow_adjust_us: u64 = 0,
    ceiling: u32 = 0, // taxa em que congestionou da última vez (0 = não sabe)
    changed: bool = false, // `bps` mudou e o encoder ainda não sabe
    /// Como estava antes do episódio em andamento (pra desfazer se for soluço).
    undo: ?Undo = null,

    const Undo = struct { at_us: u64, bps: u32, ceiling: u32, last_congestion_us: u64 };

    /// Atraso acumulado no upload que já faz pular quadro.
    pub const max_excess_us = 250_000;
    /// Atraso começando a acumular: desce de leve.
    pub const soft_excess_us = 100_000;
    /// Só sobe a taxa com o atraso praticamente zerado.
    pub const ramp_excess_us = 60_000;
    pub const min_bps = 200_000;

    pub const Signals = struct {
        now_us: u64,
        /// Atraso acumulado no caminho, acima do normal (AckWindow.excessUs).
        excess_us: u64,
        /// Quanto disso se explica por um IDR recente (AckWindow.keyAllowanceUs).
        key_allowance_us: u64 = 0,
        /// Bytes esperando na nossa fila de envio.
        queued_bytes: usize = 0,
        /// Aviso de espectador lento: piso em % do alvo (0 = sem aviso).
        slow_floor_pct: u8 = 0,
    };

    /// Começa (ou recomeça, ao mudar resolução/fps/qualidade) com um alvo novo.
    pub fn reset(rc: *RateControl, target: u32) void {
        rc.target = target;
        rc.bps = target;
        rc.changed = true;
        rc.undo = null;
    }

    /// Começa (transmissão nova) numa taxa que já se sabe que cabe nesse
    /// servidor: até 10% acima da última que ficou 10 s sem problema.
    pub fn resetFrom(rc: *RateControl, target: u32, last_good: u32) void {
        rc.reset(target);
        if (last_good > 0) rc.bps = @max(min_bps, @min(target, last_good / 10 * 11));
    }

    /// Taxa que está aguentando sem problema há 10 s (0 = ainda não sabe).
    pub fn goodBps(rc: *const RateControl, now: u64) u32 {
        const calm_since = @max(rc.last_congestion_us, rc.last_slow_us);
        if (calm_since != 0 and now - calm_since < 10_000_000) return 0;
        if (now - rc.last_adjust_us < 10_000_000 and rc.last_adjust_us != 0 and rc.bps < rc.target) return 0;
        return rc.bps;
    }

    /// Alvo novo mantendo uma redução que ainda esteja valendo.
    pub fn retarget(rc: *RateControl, target: u32) void {
        rc.target = target;
        if (rc.bps == 0 or rc.bps > target) rc.bps = target;
        rc.changed = true;
    }

    /// Taxa nova pro encoder, se mudou desde a última chamada.
    pub fn takeChange(rc: *RateControl) ?u32 {
        if (!rc.changed) return null;
        rc.changed = false;
        return rc.bps;
    }

    /// Congestionou: o teto é a taxa do começo do episódio (um episódio novo
    /// começa depois de 2 s sem problema), não a já cortada.
    fn noteCongestion(rc: *RateControl, now: u64) void {
        if (rc.last_congestion_us == 0 or now - rc.last_congestion_us > 2_000_000) {
            rc.undo = .{ .at_us = now, .bps = rc.bps, .ceiling = rc.ceiling, .last_congestion_us = rc.last_congestion_us };
            rc.ceiling = rc.bps;
        }
        rc.last_congestion_us = now;
    }

    /// O atraso voltou ao normal: se o episódio durou até BLIP, foi soluço e
    /// fica tudo como estava antes dele (taxa, teto e o relógio da calma).
    fn settle(rc: *RateControl, now: u64) void {
        const u = rc.undo orelse return;
        rc.undo = null;
        if (now -| u.at_us > BLIP) return;
        rc.ceiling = u.ceiling;
        rc.last_congestion_us = u.last_congestion_us;
        if (u.bps > rc.bps) rc.set(@min(rc.target, u.bps), now);
    }

    fn set(rc: *RateControl, bps: u32, now: u64) void {
        rc.last_adjust_us = now;
        if (bps != rc.bps) rc.changed = true;
        rc.bps = bps;
    }

    /// Chamado antes de codificar cada quadro. Retorna true = pule esse quadro.
    pub fn congested(rc: *RateControl, sig: Signals) bool {
        const now = sig.now_us;
        if (sig.slow_floor_pct != 0) {
            rc.last_slow_us = now;
            rc.undo = null; // espectador reclamando é de verdade: o corte fica
            const floor = @max(min_bps, rc.target / 100 * sig.slow_floor_pct);
            if (rc.bps > floor and now - rc.last_slow_adjust_us > 2_000_000) {
                rc.last_slow_adjust_us = now;
                rc.ceiling = rc.bps; // acima disso, só sondando devagar
                rc.set(@max(floor, rc.bps / 100 * 80), now);
            }
        }
        const excess = sig.excess_us;
        const unexplained = excess -| sig.key_allowance_us; // o que um IDR recente não explica
        const queue_ok = sig.queued_bytes <= @max(96 * 1024, rc.bps / 8 / 4);
        if (excess <= max_excess_us and queue_ok) {
            rc.congested_since_us = 0;
            if (unexplained <= ramp_excess_us) rc.settle(now);
            if (unexplained > soft_excess_us and now - rc.last_adjust_us > 500_000) {
                // começando a acumular: desce de leve antes de ter que pular quadro
                rc.noteCongestion(now);
                rc.set(@max(min_bps, rc.bps / 100 * 93), now);
            }
            return false;
        }
        // atrasou só por causa de um IDR (grande): pula quadro pra não
        // empilhar atrás dele, mas não é motivo pra baixar a qualidade
        if (unexplained <= max_excess_us and queue_ok) return true;
        if (rc.congested_since_us == 0) {
            rc.congested_since_us = now;
            rc.repeated = now - rc.last_congestion_us < 1_000_000;
        }
        rc.noteCongestion(now);
        const persistent = rc.repeated or now - rc.congested_since_us > 300_000 or unexplained > 600_000;
        if (persistent and now - rc.last_adjust_us > 400_000) {
            rc.set(@max(min_bps, rc.bps / 100 * 75), now);
        }
        return true;
    }

    /// Atraso zerado, 2 s sem congestionar e nenhum espectador reclamando há
    /// 12 s: sobe a taxa (rápido até 90% do teto; acima disso só sondando).
    pub fn rampUp(rc: *RateControl, now: u64, excess_us: u64) void {
        if (rc.bps >= rc.target or excess_us > ramp_excess_us) return;
        if (now - rc.last_congestion_us < 2_000_000 or now - rc.last_adjust_us < 1_000_000) return;
        if (rc.last_slow_us != 0 and now - rc.last_slow_us < 12_000_000) return;
        const calm = now - @max(rc.last_congestion_us, rc.last_slow_us); // tempo sem problema
        if (calm > PROBE_FORGET) rc.ceiling = 0;
        const limit = if (rc.ceiling == 0) rc.target else rc.ceiling / 100 * 90;
        const next = if (rc.bps < limit)
            @min(limit, rc.bps / 100 * 112 + 50_000)
        else if (calm > PROBE_AFTER)
            rc.bps / 100 * 102
        else
            return;
        rc.set(@min(rc.target, next), now);
    }
};
