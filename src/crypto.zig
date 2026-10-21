//! Canal criptografado entre cliente e servidor.
//!
//! Handshake (em claro): cada lado manda "TLNH", u16 versão, chave pública
//! X25519 (32 bytes) e um nonce aleatório (16 bytes). Os dois calculam o
//! segredo ECDH e derivam duas chaves (uma por direção) com HKDF-SHA256,
//! misturando o hash da senha da sala. Se a senha estiver errada, as chaves
//! não batem e a primeira mensagem não decifra — o servidor avisa e fecha.
//!
//! Depois disso cada mensagem vai cifrada com ChaCha20-Poly1305, nonce =
//! contador por direção (nunca repete dentro de uma conexão).
//!
//! Protege contra quem escuta o tráfego (túneis públicos, Wi-Fi). Contra
//! quem se põe no meio do caminho: o servidor tem uma identidade fixa
//! (Ed25519) e assina o handshake de cada conexão (mensagem `identity`, logo
//! depois do handshake); o app confere com a impressão que veio no convite
//! (telinha://...!impressão) ou com a que viu da primeira vez naquele
//! endereço. Sem isso, um atacante ativo ainda conseguiria tentar adivinhar a
//! senha offline: use senhas que não sejam óbvias.
const std = @import("std");
const sync = @import("sync.zig");
const X25519 = std.crypto.dh.X25519;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

pub const tag_len = Aead.tag_length;
pub const hello_len = 4 + 2 + 32 + 16;
const magic = "TLNH";

pub const Hello = struct {
    version: u16,
    public: [32]u8,
    nonce: [16]u8,
};

pub const Handshake = struct {
    keys: X25519.KeyPair,
    nonce: [16]u8,

    pub fn init() !Handshake {
        var seed: [32]u8 = undefined;
        sync.osRandom(&seed);
        var h: Handshake = .{ .keys = try X25519.KeyPair.generateDeterministic(seed), .nonce = undefined };
        sync.osRandom(&h.nonce);
        return h;
    }

    pub fn helloBytes(h: *const Handshake, version: u16) [hello_len]u8 {
        var out: [hello_len]u8 = undefined;
        @memcpy(out[0..4], magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        @memcpy(out[6..38], &h.keys.public_key);
        @memcpy(out[38..54], &h.nonce);
        return out;
    }
};

pub fn parseHello(bytes: *const [hello_len]u8) !Hello {
    if (!std.mem.eql(u8, bytes[0..4], magic)) return error.NotTelinha;
    return .{
        .version = std.mem.readInt(u16, bytes[4..6], .little),
        .public = bytes[6..38].*,
        .nonce = bytes[38..54].*,
    };
}

/// Identidade fixa do servidor (a semente fica num arquivo; ver server_main.zig).
pub const Identity = struct {
    kp: Ed25519.KeyPair,

    pub fn fromSeed(seed: [32]u8) !Identity {
        return .{ .kp = try Ed25519.KeyPair.generateDeterministic(seed) };
    }

    pub fn newSeed() [32]u8 {
        var seed: [32]u8 = undefined;
        sync.osRandom(&seed);
        return seed;
    }

    pub fn publicKey(id: *const Identity) [32]u8 {
        return id.kp.public_key.toBytes();
    }

    /// Assina o handshake de uma conexão (ver `transcript`).
    pub fn sign(id: *const Identity, t: [32]u8) ![64]u8 {
        return (try id.kp.sign(&t, null)).toBytes();
    }
};

/// O que o servidor assina: as duas metades do handshake (chaves e nonces
/// dos dois lados). Quem estiver no meio tem o próprio handshake com cada
/// lado, então a assinatura do servidor de verdade não serve pra ele.
pub fn transcript(client: Hello, server: Hello) [32]u8 {
    var h = Sha256.init(.{});
    h.update("telinha-identidade-v1");
    h.update(&client.public);
    h.update(&client.nonce);
    h.update(&server.public);
    h.update(&server.nonce);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

pub fn verifyIdentity(public: [32]u8, sig: [64]u8, t: [32]u8) bool {
    const pk = Ed25519.PublicKey.fromBytes(public) catch return false;
    Ed25519.Signature.fromBytes(sig).verify(&t, pk) catch return false;
    return true;
}

/// Impressão da identidade: 24 letras/números (base32 dos primeiros 15 bytes
/// do SHA-256 da chave pública: 120 bits). Vai no convite depois do "!".
pub const fp_len = 24;
pub fn fingerprint(public: [32]u8) [fp_len]u8 {
    var hash: [32]u8 = undefined;
    Sha256.hash(&public, &hash, .{});
    const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
    var out: [fp_len]u8 = undefined;
    var bits: u32 = 0;
    var acc: u32 = 0;
    var n: usize = 0;
    for (hash[0..15]) |b| {
        acc = (acc << 8) | b;
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            out[n] = alphabet[(acc >> @intCast(bits)) & 31];
            n += 1;
        }
    }
    return out;
}

/// O Hello que eu mandei (pra montar o `transcript` do meu lado).
pub fn myHello(h: *const Handshake, version: u16) Hello {
    return .{ .version = version, .public = h.keys.public_key, .nonce = h.nonce };
}

pub const Channel = struct {
    send_key: [32]u8,
    recv_key: [32]u8,
    send_ctr: u64 = 0,
    recv_ctr: u64 = 0,

    /// Deriva as chaves dos dois sentidos.
    pub fn derive(h: *const Handshake, peer: Hello, is_client: bool, password: []const u8) !Channel {
        const shared = try X25519.scalarmult(h.keys.secret_key, peer.public);
        var pw: [32]u8 = undefined;
        var hasher = Sha256.init(.{});
        hasher.update("telinha-senha-v1");
        hasher.update(password);
        hasher.final(&pw);

        var ikm: [64]u8 = undefined;
        @memcpy(ikm[0..32], &shared);
        @memcpy(ikm[32..64], &pw);
        var salt: [32]u8 = undefined;
        const client_nonce = if (is_client) h.nonce else peer.nonce;
        const server_nonce = if (is_client) peer.nonce else h.nonce;
        @memcpy(salt[0..16], &client_nonce);
        @memcpy(salt[16..32], &server_nonce);
        const prk = Hkdf.extract(&salt, &ikm);

        var c2s: [32]u8 = undefined;
        var s2c: [32]u8 = undefined;
        Hkdf.expand(&c2s, "telinha c2s", prk);
        Hkdf.expand(&s2c, "telinha s2c", prk);
        return if (is_client)
            .{ .send_key = c2s, .recv_key = s2c }
        else
            .{ .send_key = s2c, .recv_key = c2s };
    }

    fn nonce(ctr: u64) [Aead.nonce_length]u8 {
        var n = [_]u8{0} ** Aead.nonce_length;
        std.mem.writeInt(u64, n[0..8], ctr, .little);
        return n;
    }

    /// Cifra `plain` em `out` (precisa ter plain.len + tag_len bytes).
    pub fn seal(ch: *Channel, plain: []const u8, out: []u8) void {
        std.debug.assert(out.len == plain.len + tag_len);
        Aead.encrypt(out[0..plain.len], out[plain.len..][0..tag_len], plain, "", nonce(ch.send_ctr), ch.send_key);
        ch.send_ctr += 1;
    }

    /// Decifra `cipher` (com a tag no fim) em `out` (cipher.len - tag_len bytes).
    pub fn open(ch: *Channel, cipher: []const u8, out: []u8) !void {
        if (cipher.len < tag_len or out.len != cipher.len - tag_len) return error.BadMessage;
        const n = cipher.len - tag_len;
        Aead.decrypt(out, cipher[0..n], cipher[n..][0..tag_len].*, "", nonce(ch.recv_ctr), ch.recv_key) catch return error.AuthFailed;
        ch.recv_ctr += 1;
    }
};

test "identidade: assina o handshake, confere, impressão estável" {
    const id = try Identity.fromSeed([_]u8{7} ** 32);
    const a = try Handshake.init();
    const b = try Handshake.init();
    const t = transcript(myHello(&a, 6), myHello(&b, 6));
    const sig = try id.sign(t);
    try std.testing.expect(verifyIdentity(id.publicKey(), sig, t));
    // outro handshake (quem está no meio): a mesma assinatura não serve
    const c = try Handshake.init();
    try std.testing.expect(!verifyIdentity(id.publicKey(), sig, transcript(myHello(&a, 6), myHello(&c, 6))));
    // outra chave: não confere
    const other = try Identity.fromSeed([_]u8{8} ** 32);
    try std.testing.expect(!verifyIdentity(other.publicKey(), sig, t));
    const fp = fingerprint(id.publicKey());
    try std.testing.expectEqualSlices(u8, &fp, &fingerprint(id.publicKey()));
    try std.testing.expect(!std.mem.eql(u8, &fp, &fingerprint(other.publicKey())));
}
