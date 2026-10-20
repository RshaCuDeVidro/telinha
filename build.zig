//! Build do telinha.
//!
//!   zig build                 app Linux + app Windows + servidor dedicado
//!   zig build test            testes
//!   zig build run -- [args]   roda o app nativo
//!   zig build server          só o servidor dedicado (estático, musl)
//!   zig build bench           benchmark do pipeline de vídeo
//!   zig build loadtest        teste de carga do servidor
//!   zig build captest         diagnóstico da captura de tela (Linux)
//!   zig build audiotest       diagnóstico da captura do som (Linux)
//!   zig build voicebot        robô que entra numa sala e fala (teste da voz)
//!   -Dserver-only=true        não baixa as dependências do app (Docker)
//!
//! Dependências C/C++ (Dear ImGui, cimgui, openh264, GLFW, NASM) vêm do
//! gerenciador de pacotes do Zig (build.zig.zon). O NASM do sistema é usado se
//! existir; senão é compilado aqui mesmo pra montar o assembly do openh264.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "modo de otimização (padrão ReleaseFast)") orelse .ReleaseFast;
    const native_only = b.option(bool, "native-only", "compila só o app pra máquina atual") orelse false;
    const server_only = b.option(bool, "server-only", "compila só o servidor dedicado (não baixa as dependências do app)") orelse false;
    // dono/repositório no GitHub (o CI passa): o app avisa quando sai versão nova
    const repo = b.option([]const u8, "repo", "repositório no GitHub (dono/nome) pra checar versão nova") orelse "";
    // alvo do app nativo: a máquina atual por padrão; releases usam -Dcpu=x86_64_v2
    const host = b.standardTargetOptions(.{});
    const windows_cpu: std.Target.Query.CpuModel = if (host.query.cpu_model == .explicit) host.query.cpu_model else .baseline;
    const windows = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .cpu_model = windows_cpu });

    // servidor dedicado: binário estático (musl), sem dependência nenhuma
    const server_step = b.step("server", "servidor dedicado (Linux x86_64 e aarch64, estático)");
    for ([_]std.Target.Cpu.Arch{ .x86_64, .aarch64 }) |arch| {
        const t = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .musl });
        const exe = serverExe(b, t, optimize);
        const install = b.addInstallArtifact(exe, .{ .dest_sub_path = b.fmt("telinha-server-{s}", .{@tagName(arch)}) });
        server_step.dependOn(&install.step);
        if (!native_only) b.getInstallStep().dependOn(&install.step);
    }
    if (server_only) return;

    // dependências do app (lazy: na primeira vez o zig baixa e roda o build de novo)
    const imgui = b.lazyDependency("imgui", .{});
    const cimgui = b.lazyDependency("cimgui", .{});
    const oh264 = b.lazyDependency("openh264", .{});
    const glfw = b.lazyDependency("glfw", .{});
    const nvh = b.lazyDependency("nv_codec_headers", .{});
    const libva = b.lazyDependency("libva", .{});
    const opus = b.lazyDependency("opus", .{});
    const miniaudio = b.lazyDependency("miniaudio", .{});
    const rnnoise = b.lazyDependency("rnnoise", .{});
    const speexdsp = b.lazyDependency("speexdsp", .{});
    const stb = b.lazyDependency("stb", .{});
    const nasm = nasmProgram(b) orelse return;
    const deps: Deps = .{
        .imgui = imgui orelse return,
        .cimgui = cimgui orelse return,
        .openh264 = oh264 orelse return,
        .glfw = glfw orelse return,
        .nv_headers = nvh orelse return,
        .libva = libva orelse return,
        .opus = opus orelse return,
        .miniaudio = miniaudio orelse return,
        .rnnoise = rnnoise orelse return,
        .speexdsp = speexdsp orelse return,
        .stb = stb orelse return,
        .nasm = nasm,
        .options = b.addOptions(),
    };
    deps.options.addOption([]const u8, "repo", repo);

    // app
    const native_app = app(b, deps, host, optimize);
    b.installArtifact(native_app);
    if (!native_only and host.result.os.tag != .windows) b.installArtifact(app(b, deps, windows, optimize));

    const run = b.addRunArtifact(native_app);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "roda o app").dependOn(&run.step);

    // testes (unitários + integração do servidor + codec)
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = host,
        .optimize = .Debug,
        .link_libc = true,
        .link_libcpp = true,
    });
    linkOpenh264(b, deps, tests_mod, host, .ReleaseFast);
    addHwenc(b, deps, tests_mod);
    addAudio(b, deps, tests_mod, host, .ReleaseFast);
    tests_mod.addCSourceFile(.{ .file = b.path("src/c/debugsys.c"), .flags = &.{"-O2"} });
    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "roda os testes").dependOn(&run_tests.step);

    // teste de carga do servidor
    const load_mod = b.createModule(.{
        .root_source_file = b.path("src/loadtest.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .link_libcpp = true,
    });
    linkOpenh264(b, deps, load_mod, host, .ReleaseFast);
    addHwenc(b, deps, load_mod);
    const run_load = b.addRunArtifact(b.addExecutable(.{ .name = "loadtest", .root_module = load_mod }));
    if (b.args) |args| run_load.addArgs(args);
    b.step("loadtest", "teste de carga do servidor (espectadores simulados)").dependOn(&run_load.step);

    // robô de voz (testa a voz da sala sem microfone)
    const vb_mod = b.createModule(.{
        .root_source_file = b.path("src/voicebot.zig"),
        .target = host,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .link_libcpp = true,
    });
    linkOpenh264(b, deps, vb_mod, host, .ReleaseFast);
    addHwenc(b, deps, vb_mod);
    addAudio(b, deps, vb_mod, host, .ReleaseFast);
    const vb_exe = b.addExecutable(.{ .name = "voicebot", .root_module = vb_mod });
    const run_vb = b.addRunArtifact(vb_exe);
    if (b.args) |args| run_vb.addArgs(args);
    b.step("voicebot", "robô que entra numa sala e fala (teste da voz)").dependOn(&run_vb.step);
    b.getInstallStep().dependOn(&b.addInstallArtifact(vb_exe, .{ .dest_dir = .{ .override = .{ .custom = "tools" } } }).step);

    // diagnóstico da captura (Linux)
    if (host.result.os.tag == .linux) {
        const cap_mod = b.createModule(.{
            .root_source_file = b.path("src/captest.zig"),
            .target = host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
        cap_mod.addIncludePath(b.path("src/c"));
        cap_mod.addIncludePath(deps.nv_headers.path("include"));
        cap_mod.addCSourceFile(.{ .file = b.path("src/c/capture_linux.c"), .flags = &.{"-O2"} });
        cap_mod.addCSourceFile(.{ .file = b.path("src/c/cudagl.c"), .flags = &.{ "-O2", "-Wno-everything" } });
        for ([_][]const u8{ "libportal", "libpipewire-0.3", "x11", "xext", "xfixes" }) |lib|
            cap_mod.linkSystemLibrary(lib, .{});
        const cap_exe = b.addExecutable(.{ .name = "captest", .root_module = cap_mod });
        const run_cap = b.addRunArtifact(cap_exe);
        if (b.args) |args| run_cap.addArgs(args);
        b.step("captest", "diagnóstico da captura de tela").dependOn(&run_cap.step);
        b.getInstallStep().dependOn(&b.addInstallArtifact(cap_exe, .{ .dest_dir = .{ .override = .{ .custom = "tools" } } }).step);

        // diagnóstico da captura do som (o próprio app não pode aparecer nela)
        const aud_mod = b.createModule(.{
            .root_source_file = b.path("src/audiotest.zig"),
            .target = host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
        addAudio(b, deps, aud_mod, host, .ReleaseFast);
        const aud_exe = b.addExecutable(.{ .name = "audiotest", .root_module = aud_mod });
        const run_aud = b.addRunArtifact(aud_exe);
        if (b.args) |args| run_aud.addArgs(args);
        b.step("audiotest", "diagnóstico da captura do som do computador").dependOn(&run_aud.step);
        b.getInstallStep().dependOn(&b.addInstallArtifact(aud_exe, .{ .dest_dir = .{ .override = .{ .custom = "tools" } } }).step);
    }

    // benchmark do pipeline de vídeo
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = host,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true,
    });
    linkOpenh264(b, deps, bench_mod, host, .ReleaseFast);
    addHwenc(b, deps, bench_mod);
    const run_bench = b.addRunArtifact(b.addExecutable(.{ .name = "bench", .root_module = bench_mod }));
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "mede conversão/encode/decode H.264").dependOn(&run_bench.step);
}

const Deps = struct {
    imgui: *std.Build.Dependency,
    cimgui: *std.Build.Dependency,
    openh264: *std.Build.Dependency,
    glfw: *std.Build.Dependency,
    nv_headers: *std.Build.Dependency,
    libva: *std.Build.Dependency,
    opus: *std.Build.Dependency,
    miniaudio: *std.Build.Dependency,
    rnnoise: *std.Build.Dependency,
    speexdsp: *std.Build.Dependency,
    stb: *std.Build.Dependency,
    nasm: NasmProgram,
    options: *std.Build.Step.Options, // build_options do app (repo)
};

/// Opus (áudio) em ponto flutuante + o shim de áudio com miniaudio.
fn addAudio(b: *std.Build, deps: Deps, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const om = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    const lib = b.addLibrary(.{ .name = "opus", .root_module = om, .linkage = .static });
    for ([_][]const u8{ "include", "celt", "silk", "silk/float", "src" }) |p| om.addIncludePath(deps.opus.path(p));
    om.addCSourceFiles(.{
        .root = deps.opus.path("."),
        .files = &(opus_celt ++ opus_silk ++ opus_silk_float ++ opus_src),
        .flags = &.{ "-DOPUS_BUILD", "-DUSE_ALLOCA", "-DHAVE_LRINTF", "-DHAVE_LRINT", "-DPACKAGE_VERSION=\"1.6.1\"", "-O2", "-Wno-everything" },
    });
    mod.linkLibrary(lib);
    mod.addIncludePath(deps.opus.path("include"));
    mod.addIncludePath(deps.miniaudio.path("."));
    mod.addIncludePath(b.path("src/c"));
    mod.addCSourceFile(.{ .file = b.path("src/c/audio.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    // apertar pra falar (a voz lê a tecla na thread do microfone)
    mod.addCSourceFile(.{ .file = b.path("src/c/ptt.c"), .flags = &.{"-O2"} });
    if (target.result.os.tag == .linux) mod.linkSystemLibrary("x11", .{});
    addRnnoise(b, deps, mod, target, optimize);
    addSpeexdsp(b, deps, mod, target, optimize);
    // Linux: som dos aplicativos pelo grafo do PipeWire (sem o próprio telinha)
    if (target.result.os.tag == .linux) {
        mod.addCSourceFile(.{ .file = b.path("src/c/audio_pw.c"), .flags = &.{ "-O2", "-Wno-everything" } });
        mod.linkSystemLibrary("libpipewire-0.3", .{});
    }
}

/// SpeexDSP: só o cancelamento de eco (MDF) e a supressão do eco que sobra.
fn addSpeexdsp(b: *std.Build, deps: Deps, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const om = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    const lib = b.addLibrary(.{ .name = "speexdsp", .root_module = om, .linkage = .static });
    om.addIncludePath(b.path("src/c/speexdsp")); // config.h e speexdsp_config_types.h
    om.addIncludePath(deps.speexdsp.path("include"));
    om.addIncludePath(deps.speexdsp.path("libspeexdsp"));
    om.addCSourceFiles(.{
        .root = deps.speexdsp.path("libspeexdsp"),
        .files = &.{ "mdf.c", "preprocess.c", "filterbank.c", "fftwrap.c", "smallft.c" },
        .flags = &.{ "-O2", "-Wno-everything", "-DHAVE_CONFIG_H" },
    });
    om.linkSystemLibrary("m", .{});
    mod.linkLibrary(lib);
    mod.addIncludePath(b.path("src/c/speexdsp"));
    mod.addIncludePath(deps.speexdsp.path("include"));
}

/// RNNoise (supressão de ruído da voz). No x86_64 escolhe SSE4.1/AVX2 em runtime.
fn addRnnoise(b: *std.Build, deps: Deps, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const om = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    const lib = b.addLibrary(.{ .name = "rnnoise", .root_module = om, .linkage = .static });
    om.addIncludePath(deps.rnnoise.path("include"));
    om.addIncludePath(deps.rnnoise.path("src"));
    const x86 = target.result.cpu.arch == .x86_64;
    const flags: []const []const u8 = if (x86)
        &.{ "-O2", "-Wno-everything", "-DRNN_ENABLE_X86_RTCD", "-DCPU_INFO_BY_C" }
    else
        &.{ "-O2", "-Wno-everything" };
    om.addCSourceFiles(.{ .root = deps.rnnoise.path("src"), .files = &rnnoise_src, .flags = flags });
    if (x86) {
        om.addCSourceFiles(.{ .root = deps.rnnoise.path("src"), .files = &.{ "x86/x86_dnn_map.c", "x86/x86cpu.c" }, .flags = flags });
        // as versões SSE4.1/AVX2 compilam com essas instruções ligadas (o zig
        // fixa os recursos da CPU por alvo, -mavx2 por arquivo não vale); só
        // são chamadas se a CPU tiver (detecção em runtime)
        const F = std.Target.x86.Feature;
        for ([_]struct { file: []const u8, feats: []const F }{
            .{ .file = "x86/nnet_sse4_1.c", .feats = &.{.sse4_1} },
            .{ .file = "x86/nnet_avx2.c", .feats = &.{ .avx2, .fma } },
        }) |v| {
            var q = target.query;
            for (v.feats) |f| q.cpu_features_add.addFeature(@intFromEnum(f));
            const vm = b.createModule(.{ .target = b.resolveTargetQuery(q), .optimize = optimize, .link_libc = true });
            vm.addIncludePath(deps.rnnoise.path("include"));
            vm.addIncludePath(deps.rnnoise.path("src"));
            vm.addCSourceFiles(.{ .root = deps.rnnoise.path("src"), .files = &.{v.file}, .flags = flags });
            om.linkLibrary(b.addLibrary(.{ .name = "rnnoise_simd", .root_module = vm, .linkage = .static }));
        }
    }
    mod.linkLibrary(lib);
    mod.addIncludePath(deps.rnnoise.path("include"));
}

const rnnoise_src = [_][]const u8{
    "denoise.c",              "rnn.c",          "pitch.c",          "kiss_fft.c", "celt_lpc.c", "nnet.c", "nnet_default.c",
    "parse_lpcnet_weights.c", "rnnoise_data.c", "rnnoise_tables.c",
};

/// Encoder/decoder em hardware (NVENC/NVDEC; VA-API no Linux, Media
/// Foundation no Windows). As libs do driver são carregadas em runtime: dos
/// projetos só vêm os headers. O hwva.c usa o decoder do openh264 no
/// autoteste, então quem chama addHwenc já tem que ter chamado linkOpenh264.
fn addHwenc(b: *std.Build, deps: Deps, mod: *std.Build.Module) void {
    mod.addIncludePath(deps.nv_headers.path("include"));
    mod.addIncludePath(b.path("src/c"));
    mod.addCSourceFile(.{ .file = b.path("src/c/hwenc.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    mod.addCSourceFile(.{ .file = b.path("src/c/cudagl.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    mod.addCSourceFile(.{ .file = b.path("src/c/hwenc_nvenc.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    if (mod.resolved_target.?.result.os.tag == .windows)
        mod.addCSourceFile(.{ .file = b.path("src/c/hwenc_mf.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    mod.addCSourceFile(.{ .file = b.path("src/c/hwdec_nvdec.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    mod.addCSourceFile(.{ .file = b.path("src/c/hwdec.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    if (mod.resolved_target.?.result.os.tag == .windows)
        mod.addCSourceFile(.{ .file = b.path("src/c/hwdec_mf.c"), .flags = &.{ "-O2", "-Wno-everything" } })
    else {
        // va_version.h é gerado pelo build do libva; aqui basta a versão da API dos headers (2.22.0 = VA-API 1.22)
        const wf = b.addWriteFiles();
        _ = wf.add("va/va_version.h",
            \\#pragma once
            \\#define VA_MAJOR_VERSION 1
            \\#define VA_MINOR_VERSION 22
            \\#define VA_MICRO_VERSION 0
            \\#define VA_VERSION 1.22.0
            \\#define VA_VERSION_S "1.22.0"
            \\#define VA_VERSION_HEX ((VA_MAJOR_VERSION << 24) | (VA_MINOR_VERSION << 16) | (VA_MICRO_VERSION << 8))
            \\#define VA_CHECK_VERSION(major, minor, micro) (VA_MAJOR_VERSION > (major) || (VA_MAJOR_VERSION == (major) && VA_MINOR_VERSION > (minor)) || (VA_MAJOR_VERSION == (major) && VA_MINOR_VERSION == (minor) && VA_MICRO_VERSION >= (micro)))
            \\
        );
        mod.addIncludePath(wf.getDirectory());
        mod.addIncludePath(deps.libva.path("."));
        mod.addCSourceFile(.{ .file = b.path("src/c/hwva.c"), .flags = &.{ "-O2", "-Wno-everything" } });
    }
}

const NasmProgram = union(enum) {
    system: []const u8,
    built: *std.Build.Step.Compile,
};

// ---------------------------------------------------------------------------
// NASM

fn nasmProgram(b: *std.Build) ?NasmProgram {
    if (b.findProgram(&.{"nasm"}, &.{})) |path| return .{ .system = path } else |_| {}
    const dep = b.lazyDependency("nasm", .{}) orelse return null;
    const mod = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true });
    const exe = b.addExecutable(.{ .name = "nasm", .root_module = mod });
    mod.addIncludePath(b.path("tools/nasm")); // config/config.h (gerado pelo configure do NASM)
    for ([_][]const u8{ "include", ".", "x86", "asm", "disasm", "output" }) |p| mod.addIncludePath(dep.path(p));
    mod.addCSourceFiles(.{
        .root = dep.path("."),
        .files = &nasm_sources,
        .flags = &.{ "-DHAVE_CONFIG_H", "-Wno-date-time", "-std=gnu11" },
    });
    return .{ .built = exe };
}

fn assemble(b: *std.Build, deps: Deps, src: std.Build.LazyPath, target: std.Build.ResolvedTarget) std.Build.LazyPath {
    const run = switch (deps.nasm) {
        .system => |p| b.addSystemCommand(&.{p}),
        .built => |exe| b.addRunArtifact(exe),
    };
    if (target.result.os.tag == .windows) {
        run.addArgs(&.{ "-f", "win64", "-DWIN64", "-DHAVE_AVX2" });
    } else {
        run.addArgs(&.{ "-f", "elf64", "-DUNIX64", "-DHAVE_AVX2" });
    }
    run.addPrefixedDirectoryArg("-I", deps.openh264.path("codec/common/x86"));
    run.addFileArg(src);
    run.addArg("-o");
    return run.addOutputFileArg("out.o");
}

// ---------------------------------------------------------------------------
// openh264 (H.264 com assembly SIMD no x86_64). Cada parte vira uma lib
// separada porque decoder e encoder têm headers com o mesmo nome.

fn linkOpenh264(b: *std.Build, deps: Deps, into: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const dep = deps.openh264;
    const x86 = target.result.cpu.arch == .x86_64;
    const flags: []const []const u8 = if (x86)
        &.{ "-DNDEBUG", "-fno-exceptions", "-fno-rtti", "-DX86_ASM", "-DHAVE_AVX2", "-Wno-everything" }
    else
        &.{ "-DNDEBUG", "-fno-exceptions", "-fno-rtti", "-Wno-everything" };

    const Part = struct { name: []const u8, dir: []const u8, cpp: []const []const u8, asm_: []const []const u8, inc: []const []const u8 };
    const parts = [_]Part{
        .{ .name = "common", .dir = "codec/common", .cpp = &oh_common_cpp, .asm_ = &oh_common_asm, .inc = &.{} },
        .{ .name = "decoder", .dir = "codec/decoder", .cpp = &oh_decoder_cpp, .asm_ = &oh_decoder_asm, .inc = &.{ "codec/decoder/core/inc", "codec/decoder/plus/inc" } },
        .{ .name = "encoder", .dir = "codec/encoder", .cpp = &oh_encoder_cpp, .asm_ = &oh_encoder_asm, .inc = &.{ "codec/encoder/core/inc", "codec/encoder/plus/inc", "codec/processing/interface" } },
        .{ .name = "processing", .dir = "codec/processing", .cpp = &oh_processing_cpp, .asm_ = &oh_processing_asm, .inc = &oh_processing_inc },
    };
    for (parts) |part| {
        const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true, .link_libcpp = true });
        const lib = b.addLibrary(.{ .name = b.fmt("openh264_{s}", .{part.name}), .root_module = mod, .linkage = .static });
        for ([_][]const u8{ "codec/api", "codec/api/wels", "codec/common/inc" }) |inc| mod.addIncludePath(dep.path(inc));
        for (part.inc) |inc| mod.addIncludePath(dep.path(inc));
        mod.addCSourceFiles(.{ .root = dep.path(part.dir), .files = part.cpp, .flags = flags });
        if (x86) for (part.asm_) |a| mod.addObjectFile(assemble(b, deps, dep.path(b.fmt("{s}/{s}", .{ part.dir, a })), target));
        into.linkLibrary(lib);
    }
    into.addIncludePath(dep.path("codec/api"));
}

// ---------------------------------------------------------------------------
// Dear ImGui + cimgui

fn addImgui(b: *std.Build, deps: Deps, mod: *std.Build.Module) void {
    const flags: []const []const u8 = &.{
        "-fno-exceptions",
        "-fno-rtti",
        "-DIMGUI_IMPL_API=extern \"C\"",
        "-DCIMGUI_USE_GLFW",
        "-DCIMGUI_USE_OPENGL3",
        // ganchos de teste: só trabalham com TELINHA_QA (ver src/c/qa_hooks.cpp)
        "-DIMGUI_ENABLE_TEST_ENGINE",
    };
    // o cimgui inclui "./imgui/imgui.h": montamos um diretório com essa cara
    // (todos os includes apontam pra essa cópia, senão o mesmo header entra
    // por dois caminhos e o #pragma once não pega)
    const wf = b.addWriteFiles();
    const imgui_copy = wf.addCopyDirectory(deps.imgui.path("."), "imgui", .{ .include_extensions = &.{".h"} });
    mod.addIncludePath(wf.getDirectory());
    mod.addIncludePath(imgui_copy);
    mod.addIncludePath(imgui_copy.path(b, "backends"));
    mod.addIncludePath(deps.cimgui.path("."));
    mod.addCSourceFiles(.{
        .root = deps.imgui.path("."),
        .files = &.{ "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp", "imgui_demo.cpp", "backends/imgui_impl_glfw.cpp", "backends/imgui_impl_opengl3.cpp" },
        .flags = flags,
    });
    mod.addCSourceFiles(.{ .root = deps.cimgui.path("."), .files = &.{ "cimgui.cpp", "cimgui_impl.cpp" }, .flags = flags });
    mod.addCSourceFile(.{ .file = b.path("src/c/qa_hooks.cpp"), .flags = flags });

    // cimgui.h que o translate-c do Zig aceita (ver tools/patch_cimgui.zig)
    const tool = b.addExecutable(.{
        .name = "patch_cimgui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch_cimgui.zig"),
            .target = b.graph.host,
            .optimize = .Debug, // ReleaseSafe liga o FORTIFY da glibc, que o translate-c não traduz
            .link_libc = true,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(deps.cimgui.path("cimgui.h"));
    mod.addIncludePath(run.addOutputFileArg("cimgui_zig.h").dirname());
}

// ---------------------------------------------------------------------------
// GLFW (Windows: compilado aqui; Linux: biblioteca do sistema)

fn glfwWindows(b: *std.Build, deps: Deps, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    const lib = b.addLibrary(.{ .name = "glfw", .root_module = mod, .linkage = .static });
    mod.addCSourceFiles(.{
        .root = deps.glfw.path("src"),
        .files = &.{
            "context.c",       "init.c",         "input.c",          "monitor.c",      "platform.c",     "vulkan.c",
            "window.c",        "egl_context.c",  "osmesa_context.c", "null_init.c",    "null_monitor.c", "null_window.c",
            "null_joystick.c", "win32_module.c", "win32_time.c",     "win32_thread.c", "win32_init.c",   "win32_joystick.c",
            "win32_monitor.c", "win32_window.c", "wgl_context.c",
        },
        .flags = &.{ "-D_GLFW_WIN32", "-Wno-everything" },
    });
    mod.addIncludePath(deps.glfw.path("include"));
    for ([_][]const u8{ "gdi32", "user32", "shell32" }) |l| mod.linkSystemLibrary(l, .{});
    return lib;
}

// ---------------------------------------------------------------------------

fn app(b: *std.Build, deps: Deps, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const is_windows = target.result.os.tag == .windows;
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .strip = optimize != .Debug,
    });
    mod.addIncludePath(b.path("src/c"));
    mod.addOptions("build_options", deps.options);
    // imagens do chat (stb_image só lê arquivo/área de transferência locais)
    mod.addIncludePath(deps.stb.path(""));
    mod.addCSourceFile(.{ .file = b.path("src/c/image.c"), .flags = &.{"-O2"} });
    // log de depuração (desvio da saída de erro, CPU/memória, envio do arquivo)
    mod.addCSourceFile(.{ .file = b.path("src/c/debugsys.c"), .flags = &.{"-O2"} });
    mod.addCSourceFile(.{ .file = b.path("src/c/crash.c"), .flags = &.{"-O2"} });
    addImgui(b, deps, mod);
    linkOpenh264(b, deps, mod, target, optimize);
    addHwenc(b, deps, mod);
    addAudio(b, deps, mod, target, optimize);

    if (is_windows) {
        mod.addIncludePath(deps.glfw.path("include"));
        mod.linkLibrary(glfwWindows(b, deps, target, optimize));
        mod.addCSourceFile(.{ .file = b.path("src/c/capture_win.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/camera_win.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/notify_win.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/netaddr_win.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/httpget_win.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/audio_apps_win.c"), .flags = &.{"-O2"} });
        mod.addWin32ResourceFile(.{ .file = b.path("assets/telinha.rc") });
        for ([_][]const u8{ "opengl32", "gdi32", "user32", "shell32", "ws2_32", "d3d11", "dxgi", "ole32", "dwmapi", "winmm", "advapi32", "iphlpapi", "winhttp" }) |lib|
            mod.linkSystemLibrary(lib, .{});
    } else {
        mod.addCSourceFile(.{ .file = b.path("src/c/capture_linux.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/camera_linux.c"), .flags = &.{"-O2"} });
        mod.addCSourceFile(.{ .file = b.path("src/c/notify_linux.c"), .flags = &.{"-O2"} });
        for ([_][]const u8{ "glfw3", "gl", "libportal", "libpipewire-0.3", "x11", "xext", "xfixes" }) |lib|
            mod.linkSystemLibrary(lib, .{});
    }

    const exe = b.addExecutable(.{ .name = "telinha", .root_module = mod });
    if (is_windows) exe.subsystem = .windows;
    return exe;
}

fn serverExe(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return b.addExecutable(.{ .name = "telinha-server", .root_module = b.createModule(.{
        .root_source_file = b.path("src/server_main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .Debug,
    }) });
}

// ---------------------------------------------------------------------------
// Listas de fontes (tiradas dos meson.build/Makefile.in originais)

const nasm_sources = [_][]const u8{
    "asm/nasm.c",         "asm/warnings.c",      "stdlib/snprintf.c", "stdlib/vsnprintf.c", "stdlib/strlcpy.c",
    "stdlib/strnlen.c",   "stdlib/strrchrnul.c", "nasmlib/ver.c",     "nasmlib/alloc.c",    "nasmlib/asprintf.c",
    "nasmlib/crc32.c",    "nasmlib/crc64.c",     "nasmlib/md5c.c",    "nasmlib/string.c",   "nasmlib/nctype.c",
    "nasmlib/file.c",     "nasmlib/mmap.c",      "nasmlib/ilog2.c",   "nasmlib/realpath.c", "nasmlib/path.c",
    "nasmlib/filename.c", "nasmlib/rlimit.c",    "nasmlib/readnum.c", "nasmlib/numstr.c",   "nasmlib/zerobuf.c",
    "nasmlib/bsi.c",      "nasmlib/rbtree.c",    "nasmlib/hashtbl.c", "nasmlib/raa.c",      "nasmlib/saa.c",
    "nasmlib/strlist.c",  "nasmlib/perfhash.c",  "nasmlib/badenum.c", "common/common.c",    "x86/insnsa.c",
    "x86/insnsb.c",       "x86/insnsd.c",        "x86/insnsn.c",      "x86/regs.c",         "x86/regvals.c",
    "x86/regflags.c",     "x86/regdis.c",        "x86/disp8.c",       "x86/iflag.c",        "asm/error.c",
    "asm/floats.c",       "asm/directiv.c",      "asm/directbl.c",    "asm/pragma.c",       "asm/assemble.c",
    "asm/labels.c",       "asm/parser.c",        "asm/preproc.c",     "asm/quote.c",        "asm/pptok.c",
    "asm/listing.c",      "asm/eval.c",          "asm/exprlib.c",     "asm/exprdump.c",     "asm/stdscan.c",
    "asm/strfunc.c",      "asm/tokhash.c",       "asm/segalloc.c",    "asm/rdstrnum.c",     "asm/srcfile.c",
    "macros/macros.c",    "output/outform.c",    "output/outlib.c",   "output/legacy.c",    "output/nulldbg.c",
    "output/nullout.c",   "output/outbin.c",     "output/outaout.c",  "output/outcoff.c",   "output/outelf.c",
    "output/outobj.c",    "output/outas86.c",    "output/outdbg.c",   "output/outieee.c",   "output/outmacho.c",
    "output/codeview.c",  "disasm/disasm.c",     "disasm/sync.c",
};

const oh_common_cpp = [_][]const u8{ "src/common_tables.cpp", "src/copy_mb.cpp", "src/cpu.cpp", "src/crt_util_safe_x.cpp", "src/deblocking_common.cpp", "src/expand_pic.cpp", "src/intra_pred_common.cpp", "src/mc.cpp", "src/memory_align.cpp", "src/sad_common.cpp", "src/utils.cpp", "src/welsCodecTrace.cpp", "src/WelsTaskThread.cpp", "src/WelsThread.cpp", "src/WelsThreadLib.cpp", "src/WelsThreadPool.cpp" };
const oh_common_asm = [_][]const u8{ "x86/cpuid.asm", "x86/dct.asm", "x86/deblock.asm", "x86/expand_picture.asm", "x86/intra_pred_com.asm", "x86/mb_copy.asm", "x86/mc_chroma.asm", "x86/mc_luma.asm", "x86/satd_sad.asm", "x86/vaa.asm" };
const oh_decoder_cpp = [_][]const u8{ "core/src/au_parser.cpp", "core/src/bit_stream.cpp", "core/src/cabac_decoder.cpp", "core/src/deblocking.cpp", "core/src/decode_mb_aux.cpp", "core/src/decode_slice.cpp", "core/src/decoder.cpp", "core/src/decoder_core.cpp", "core/src/decoder_data_tables.cpp", "core/src/error_concealment.cpp", "core/src/fmo.cpp", "core/src/get_intra_predictor.cpp", "core/src/manage_dec_ref.cpp", "core/src/memmgr_nal_unit.cpp", "core/src/mv_pred.cpp", "core/src/parse_mb_syn_cabac.cpp", "core/src/parse_mb_syn_cavlc.cpp", "core/src/pic_queue.cpp", "core/src/rec_mb.cpp", "plus/src/welsDecoderExt.cpp", "core/src/wels_decoder_thread.cpp" };
const oh_decoder_asm = [_][]const u8{ "core/x86/dct.asm", "core/x86/intra_pred.asm" };
const oh_encoder_cpp = [_][]const u8{ "core/src/au_set.cpp", "core/src/deblocking.cpp", "core/src/decode_mb_aux.cpp", "core/src/encode_mb_aux.cpp", "core/src/encoder.cpp", "core/src/encoder_data_tables.cpp", "core/src/encoder_ext.cpp", "core/src/get_intra_predictor.cpp", "core/src/md.cpp", "core/src/mv_pred.cpp", "core/src/nal_encap.cpp", "core/src/paraset_strategy.cpp", "core/src/picture_handle.cpp", "core/src/ratectl.cpp", "core/src/ref_list_mgr_svc.cpp", "core/src/sample.cpp", "core/src/set_mb_syn_cabac.cpp", "core/src/set_mb_syn_cavlc.cpp", "core/src/slice_multi_threading.cpp", "core/src/svc_base_layer_md.cpp", "core/src/svc_enc_slice_segment.cpp", "core/src/svc_encode_mb.cpp", "core/src/svc_encode_slice.cpp", "core/src/svc_mode_decision.cpp", "core/src/svc_motion_estimate.cpp", "core/src/svc_set_mb_syn_cabac.cpp", "core/src/svc_set_mb_syn_cavlc.cpp", "core/src/wels_preprocess.cpp", "core/src/wels_task_base.cpp", "core/src/wels_task_encoder.cpp", "core/src/wels_task_management.cpp", "plus/src/welsEncoderExt.cpp" };
const oh_encoder_asm = [_][]const u8{ "core/x86/coeff.asm", "core/x86/dct.asm", "core/x86/intra_pred.asm", "core/x86/matrix_transpose.asm", "core/x86/memzero.asm", "core/x86/quant.asm", "core/x86/sample_sc.asm", "core/x86/score.asm" };
const oh_processing_cpp = [_][]const u8{ "src/adaptivequantization/AdaptiveQuantization.cpp", "src/backgrounddetection/BackgroundDetection.cpp", "src/common/memory.cpp", "src/common/WelsFrameWork.cpp", "src/common/WelsFrameWorkEx.cpp", "src/complexityanalysis/ComplexityAnalysis.cpp", "src/denoise/denoise.cpp", "src/denoise/denoise_filter.cpp", "src/downsample/downsample.cpp", "src/downsample/downsamplefuncs.cpp", "src/imagerotate/imagerotate.cpp", "src/imagerotate/imagerotatefuncs.cpp", "src/scenechangedetection/SceneChangeDetection.cpp", "src/scrolldetection/ScrollDetection.cpp", "src/scrolldetection/ScrollDetectionFuncs.cpp", "src/vaacalc/vaacalcfuncs.cpp", "src/vaacalc/vaacalculation.cpp" };
const oh_processing_asm = [_][]const u8{ "src/x86/denoisefilter.asm", "src/x86/downsample_bilinear.asm", "src/x86/vaa.asm" };
const oh_processing_inc = [_][]const u8{ "codec/processing/interface", "codec/processing/src/common", "codec/processing/src/adaptivequantization", "codec/processing/src/backgrounddetection", "codec/processing/src/complexityanalysis", "codec/processing/src/denoise", "codec/processing/src/downsample", "codec/processing/src/imagerotate", "codec/processing/src/scenechangedetection", "codec/processing/src/scrolldetection", "codec/processing/src/vaacalc" };

const opus_celt = [_][]const u8{ "celt/bands.c", "celt/celt.c", "celt/celt_encoder.c", "celt/celt_decoder.c", "celt/cwrs.c", "celt/entcode.c", "celt/entdec.c", "celt/entenc.c", "celt/kiss_fft.c", "celt/laplace.c", "celt/mathops.c", "celt/mdct.c", "celt/modes.c", "celt/pitch.c", "celt/celt_lpc.c", "celt/quant_bands.c", "celt/rate.c", "celt/vq.c" };
const opus_silk = [_][]const u8{ "silk/CNG.c", "silk/code_signs.c", "silk/init_decoder.c", "silk/decode_core.c", "silk/decode_frame.c", "silk/decode_parameters.c", "silk/decode_indices.c", "silk/decode_pulses.c", "silk/decoder_set_fs.c", "silk/dec_API.c", "silk/enc_API.c", "silk/encode_indices.c", "silk/encode_pulses.c", "silk/gain_quant.c", "silk/interpolate.c", "silk/LP_variable_cutoff.c", "silk/NLSF_decode.c", "silk/NSQ.c", "silk/NSQ_del_dec.c", "silk/PLC.c", "silk/shell_coder.c", "silk/tables_gain.c", "silk/tables_LTP.c", "silk/tables_NLSF_CB_NB_MB.c", "silk/tables_NLSF_CB_WB.c", "silk/tables_other.c", "silk/tables_pitch_lag.c", "silk/tables_pulses_per_block.c", "silk/VAD.c", "silk/control_audio_bandwidth.c", "silk/quant_LTP_gains.c", "silk/VQ_WMat_EC.c", "silk/HP_variable_cutoff.c", "silk/NLSF_encode.c", "silk/NLSF_VQ.c", "silk/NLSF_unpack.c", "silk/NLSF_del_dec_quant.c", "silk/process_NLSFs.c", "silk/stereo_LR_to_MS.c", "silk/stereo_MS_to_LR.c", "silk/check_control_input.c", "silk/control_SNR.c", "silk/init_encoder.c", "silk/control_codec.c", "silk/A2NLSF.c", "silk/ana_filt_bank_1.c", "silk/biquad_alt.c", "silk/bwexpander_32.c", "silk/bwexpander.c", "silk/debug.c", "silk/decode_pitch.c", "silk/inner_prod_aligned.c", "silk/lin2log.c", "silk/log2lin.c", "silk/LPC_analysis_filter.c", "silk/LPC_inv_pred_gain.c", "silk/table_LSF_cos.c", "silk/NLSF2A.c", "silk/NLSF_stabilize.c", "silk/NLSF_VQ_weights_laroia.c", "silk/pitch_est_tables.c", "silk/resampler.c", "silk/resampler_down2_3.c", "silk/resampler_down2.c", "silk/resampler_private_AR2.c", "silk/resampler_private_down_FIR.c", "silk/resampler_private_IIR_FIR.c", "silk/resampler_private_up2_HQ.c", "silk/resampler_rom.c", "silk/sigm_Q15.c", "silk/sort.c", "silk/sum_sqr_shift.c", "silk/stereo_decode_pred.c", "silk/stereo_encode_pred.c", "silk/stereo_find_predictor.c", "silk/stereo_quant_pred.c", "silk/LPC_fit.c" };
const opus_silk_float = [_][]const u8{ "silk/float/apply_sine_window_FLP.c", "silk/float/corrMatrix_FLP.c", "silk/float/encode_frame_FLP.c", "silk/float/find_LPC_FLP.c", "silk/float/find_LTP_FLP.c", "silk/float/find_pitch_lags_FLP.c", "silk/float/find_pred_coefs_FLP.c", "silk/float/LPC_analysis_filter_FLP.c", "silk/float/LTP_analysis_filter_FLP.c", "silk/float/LTP_scale_ctrl_FLP.c", "silk/float/noise_shape_analysis_FLP.c", "silk/float/process_gains_FLP.c", "silk/float/regularize_correlations_FLP.c", "silk/float/residual_energy_FLP.c", "silk/float/warped_autocorrelation_FLP.c", "silk/float/wrappers_FLP.c", "silk/float/autocorrelation_FLP.c", "silk/float/burg_modified_FLP.c", "silk/float/bwexpander_FLP.c", "silk/float/energy_FLP.c", "silk/float/inner_product_FLP.c", "silk/float/k2a_FLP.c", "silk/float/LPC_inv_pred_gain_FLP.c", "silk/float/pitch_analysis_core_FLP.c", "silk/float/scale_copy_vector_FLP.c", "silk/float/scale_vector_FLP.c", "silk/float/schur_FLP.c", "silk/float/sort_FLP.c" };
const opus_src = [_][]const u8{ "src/opus.c", "src/opus_decoder.c", "src/opus_encoder.c", "src/extensions.c", "src/opus_multistream.c", "src/opus_multistream_encoder.c", "src/opus_multistream_decoder.c", "src/repacketizer.c", "src/opus_projection_encoder.c", "src/opus_projection_decoder.c", "src/mapping_matrix.c", "src/analysis.c", "src/mlp.c", "src/mlp_data.c" };
