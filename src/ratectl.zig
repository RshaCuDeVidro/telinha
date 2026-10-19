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
//!     taxa em que deu problema da última vez), segura aí e, depois de 15 s
//!     sem problema, sonda devagar (+2%/s). Depois de 30 s sem problema,
//!     esquece o teto (o link pode ter melhorado).
//!
//! Espectador que não dá conta também pede menos (aviso do servidor com um
//! piso): -20% a cada 2 s no máximo, até o piso pedido, e a taxa não sobe por
//! 12 s (o tempo de ele recomeçar de um IDR e mostrar se agora dá conta).
const std = @import("std");

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
            if (unexplained > soft_excess_us and now - rc.last_adjust_us > 500_000) {
                // começando a acumular: desce de leve antes de ter que pular quadro
                rc.ceiling = rc.bps;
                rc.last_congestion_us = now;
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
        rc.last_congestion_us = now;
        const persistent = rc.repeated or now - rc.congested_since_us > 300_000 or unexplained > 600_000;
        if (persistent and now - rc.last_adjust_us > 400_000) {
            rc.ceiling = rc.bps;
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
        if (calm > 30_000_000) rc.ceiling = 0;
        const limit = if (rc.ceiling == 0) rc.target else rc.ceiling / 100 * 90;
        const next = if (rc.bps < limit)
            @min(limit, rc.bps / 100 * 112 + 50_000)
        else if (calm > 15_000_000)
            rc.bps / 100 * 102
        else
            return;
        rc.set(@min(rc.target, next), now);
    }
};
