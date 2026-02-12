-module(rebar3_grisp_flash).

% Callbacks
-export([init/1]).
-export([do/1]).
-export([format_error/1]).

-import(rebar3_grisp_util, [
    console/1,
    console/2,
    info/1,
    info/2,
    warn/1,
    warn/2,
    abort/1,
    abort/2
]).

-define(MAX_DDOT, 2).

%--- Callbacks -----------------------------------------------------------------

-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
        {namespace, grisp},
        {name, flash},
        {module, ?MODULE},
        {bare, true},
        {deps, [{default, install_deps}, {default, compile}]},
        {example, "rebar3 grisp flash"},
        {opts, [
            {relname, $n, "relname", string, "Specify the name for the release"},
            {relvsn, $v, "relvsn", string, "Specify the version of the release"},

            {bootloader, $b, "bootloader", {boolean, false},
                "Include bootloader by flashing a full eMMC image (more destructive)"},

            {yes, $y, "yes", {boolean, false}, "Skip confirmation prompt"},
            {dry_run, undefined, "dry-run", {boolean, false}, "Show what would be executed without flashing"},

            % uuu must be available in PATH

            % Primary input: flash loader booted via ROM Serial Downloader (SDP/SDPS)
            {flash_loader, undefined, "flash_loader", string,
                "Path to a flash loader image booted via Serial Downloader (e.g. U-Boot with fastboot support)"}
        ]},
        {profiles, [grisp]},
        {short_desc, "Flash GRiSP2 eMMC via NXP uuu"},
        {desc,
            "Flashes a GRiSP2 board in Serial Downloader mode using the NXP 'uuu' tool.\n"
            "\n"
            "Default behavior (no --bootloader):\n"
            "  - auto-generates a system partition image (application-only)\n"
            "  - flashes only the first system partition (A) on eMMC\n"
            "\n"
            "With --bootloader:\n"
            "  - auto-generates a full eMMC image (includes reserved boot area + partitions)\n"
            "  - flashes the whole eMMC (more destructive)\n"
            "\n"
            "Notes:\n"
            "  - This task never uses sudo automatically. If flashing fails due to USB permissions,\n"
            "    run 'uuu -udev' once and follow its instructions, then replug the board.\n"
        }
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(RState) ->
    try
        {Args, _ExtraArgs} = rebar_state:command_parsed_args(RState),

        RelNameArg = proplists:get_value(relname, Args, undefined),
        RelVsnArg = proplists:get_value(relvsn, Args, undefined),
        {RelName, RelVsn} = rebar3_grisp_util:select_release(RState, RelNameArg, RelVsnArg),

        Bootloader = proplists:get_value(bootloader, Args, false),
        Yes = proplists:get_value(yes, Args, false),
        DryRun = proplists:get_value(dry_run, Args, false),

        FlashCfg = flash_config(RState),

        FlashLoader0 = flash_loader_value(Args, FlashCfg),
        ensure_flash_loader(FlashLoader0),

        UuuPath = resolve_uuu(),

        Kind = case Bootloader of
            true -> image;
            false -> system
        end,
        ArtifactPath = rebar3_grisp_util:firmware_file_path(
            RState,
            case Kind of system -> system; image -> image end,
            RelName,
            RelVsn
        ),

        case DryRun of
            true ->
                % Dry-run should not require building firmware artifacts (which may
                % require a cross-compiled OTP package/toolchain). We only show the
                % plan and validate inputs.
                BundlePath = "<temporary>/grisp_flash.zip",
                maybe_confirm(Yes, DryRun, Kind, ArtifactPath),
                print_plan(DryRun, UuuPath, BundlePath, Kind, ArtifactPath),
                console("* Dry-run: not generating firmware artifacts or flashing."),
                {ok, RState};
            false ->
                Artifact = ensure_artifact(RState, RelName, RelVsn, Bootloader),
                #{kind := _K, path := ArtifactPath2} = Artifact,

                TempDir = mktemp_dir(),
                {ok, OrigCwd} = file:get_cwd(),
                try
                    % Prepare a working directory with predictable filenames for uuu bundle.
                    ok = file:set_cwd(TempDir),

                    ok = stage_inputs(Kind, ArtifactPath2, FlashLoader0),

                    AutoPath = filename:join(TempDir, "uuu.auto"),
                    ok = file:write_file(AutoPath, gen_script(Kind)),

                    BundlePath2 = filename:join(TempDir, "grisp_flash.zip"),
                    ok = create_bundle(BundlePath2),

                    maybe_confirm(Yes, DryRun, Kind, ArtifactPath2),

                    print_plan(DryRun, UuuPath, BundlePath2, Kind, ArtifactPath2),

                    run_uuu(UuuPath, BundlePath2, RState)
                after
                    _ = file:set_cwd(OrigCwd),
                    ok = cleanup_dir(TempDir)
                end
        end
    catch
        error:{release_not_selected, _} = E -> erlang:error(E);
        error:Reason ->
            {error, io_lib:format("~p", [Reason])}
    end.

-spec format_error(any()) -> iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

%--- Internal ------------------------------------------------------------------

flash_config(RState) ->
    Config = rebar3_grisp_util:config(RState),
    rebar3_grisp_util:get([flash], Config, []).

flash_loader_value(Args, FlashCfg) ->
    case proplists:get_value(flash_loader, Args, undefined) of
        undefined ->
            case proplists:get_value(flash_loader, FlashCfg, undefined) of
                undefined -> default_flash_loader();
                V0 -> V0
            end;
        V -> V
    end.

default_flash_loader() ->
    % Prefer the loader shipped with the plugin under priv/flash/.
    case code:priv_dir(rebar3_grisp) of
        {error, _} -> undefined;
        PrivDir ->
            P = filename:join([PrivDir, "flash", "flash_loader.bin"]),
            case filelib:is_file(P) of
                true -> P;
                false -> undefined
            end
    end.

resolve_uuu() ->
    case os:find_executable("uuu") of
        false ->
            abort(
                "Required tool 'uuu' not found in PATH.\n\n" ++
                "Install it from NXP mfgtools: https://github.com/nxp-imx/mfgtools\n" ++
                "On many Linux distros it may be packaged as 'uuu' or 'mfgtools'.\n" ++
                "After installing, ensure `uuu` is in your PATH and retry.\n",
                []
            );
        Path -> Path
    end.

mktemp_dir() ->
    case os:cmd("mktemp -d") of
        [] -> abort("Failed to create temporary directory");
        Out -> string:trim(Out)
    end.

cleanup_dir(TempDir) ->
    _ = os:cmd("rm -rf '" ++ TempDir ++ "'"),
    ok.

create_bundle(BundlePath) ->
    % We assume 'uuu.auto' is staged into TempDir already.
    % Include everything in the current working directory.
    case os:find_executable("zip") of
        false ->
            abort(
                "Required tool 'zip' not found in PATH.\n\n" ++
                "This task creates a temporary uuu bundle as a .zip (containing uuu.auto and payloads).\n" ++
                "Install zip (e.g. 'zip' package) and retry.\n",
                []
            );
        _ ->
            Cmd = "zip -q -r '" ++ BundlePath ++ "' .",
            _ = os:cmd(Cmd),
            ok
    end.

ensure_flash_loader(undefined) ->
    abort(
        "Missing --flash_loader.\n\n" ++
        "This task generates a uuu.auto and needs a flash loader image booted via ROM Serial Downloader\n" ++
        "(typically U-Boot with fastboot support).\n" ++
        "Provide it via --flash_loader /path/to/flash_loader.bin (or configure it in rebar.config).\n",
        []
    );
ensure_flash_loader(FlashLoaderPath) ->
    case filelib:is_file(FlashLoaderPath) of
        true -> ok;
        false -> abort("--flash_loader file not found: ~s", [FlashLoaderPath])
    end.

ensure_artifact(RState, RelName, RelVsn, Bootloader) ->
    case Bootloader of
        false ->
            % System partition image only, uncompressed (but filename may still end with .gz).
            console("* Ensuring system partition artifact exists (no bootloader)...", []),
            ok = run_firmware(RState, RelName, RelVsn, [
                "--system", "true",
                "--image", "false",
                "--bootloader", "false",
                "--compress", "false",
                "--quiet"
            ]),
            Path = rebar3_grisp_util:firmware_file_path(RState, system, RelName, RelVsn),
            ensure_file(Path),
            #{kind => system, path => Path};
        true ->
            console("* Ensuring full eMMC image artifact exists (--bootloader)...", []),
            ok = run_firmware(RState, RelName, RelVsn, [
                "--system", "false",
                "--image", "true",
                "--bootloader", "false",
                "--compress", "false",
                "--truncate", "false",
                "--quiet"
            ]),
            Path = rebar3_grisp_util:firmware_file_path(RState, image, RelName, RelVsn),
            ensure_file(Path),
            #{kind => image, path => Path}
    end.

ensure_file(Path) ->
    case filelib:is_file(Path) of
        true -> ok;
        false -> abort("Expected artifact not found: ~s", [Path])
    end.

run_firmware(RState, RelName, RelVsn, FirmwareArgs) ->
    Profiles = rebar_state:current_profiles(RState),
    ProfileArgs = case Profiles of
        [] -> [];
        _ -> ["as", lists:join(",", [atom_to_list(P) || P <- Profiles])]
    end,
    Args = ProfileArgs ++ [
        "grisp",
        "firmware",
        "--relname", atom_to_list(RelName),
        "--relvsn", RelVsn
    ] ++ FirmwareArgs,
    case rebar3:run(Args) of
        {ok, _} -> ok;
        {error, Reason} -> abort("Failed to generate firmware artifacts: ~p", [Reason])
    end.

stage_inputs(system, ArtifactPath, FlashLoaderPath) ->
    ok = copy(FlashLoaderPath, "flash_loader.bin"),
    ok = copy(ArtifactPath, "sys.img"),
    ok;
stage_inputs(image, ArtifactPath, FlashLoaderPath) ->
    ok = copy(FlashLoaderPath, "flash_loader.bin"),
    ok = copy(ArtifactPath, "emmc.img"),
    ok.

copy(Src, Dest) ->
    case file:copy(Src, Dest) of
        {ok, _} -> ok;
        {error, Reason} -> abort("Failed to copy ~s -> ~s: ~s", [Src, Dest, file:format_error(Reason)])
    end.

maybe_confirm(true, _DryRun, _Kind, _ArtifactPath) -> ok;
maybe_confirm(_Yes, true, _Kind, _ArtifactPath) -> ok;
maybe_confirm(false, false, Kind, ArtifactPath) ->
    RelPath = grisp_tools_util:maybe_relative(ArtifactPath, ?MAX_DDOT),
    KindStr = case Kind of system -> "system partition"; image -> "full eMMC" end,
    console("\nAbout to flash GRiSP2 via uuu."),
    console("  Target: ~s", [KindStr]),
    console("  Artifact: ~s", [RelPath]),
    console("\nThis will overwrite data on the device. Type 'flash' to continue: "),
    case io:get_line("") of
        "flash\n" -> ok;
        _ -> abort("Aborted", [])
    end.

print_plan(true, UuuPath, BundlePath, Kind, ArtifactPath) ->
    KindStr = case Kind of system -> "system"; image -> "image" end,
    RelPath = grisp_tools_util:maybe_relative(ArtifactPath, ?MAX_DDOT),
    console("* Plan:"),
    console("  kind: ~s", [KindStr]),
    console("  artifact: ~s", [RelPath]),
    console("  uuu: ~s", [UuuPath]),
    console("  bundle: ~s", [BundlePath]);
print_plan(false, _UuuPath, _BundlePath, _Kind, _ArtifactPath) -> ok.

run_uuu(UuuPath, BundlePath, RState) ->
    Cmd = io_lib:format("'~s' '~s' 2>&1", [UuuPath, BundlePath]),
    Out = os:cmd(lists:flatten(Cmd)),
    % uuu doesn't give us a reliable exit status via os:cmd; best-effort heuristics:
    case string:find(Out, "Error") of
        nomatch ->
            console("* uuu output:\n~s", [Out]),
            console("* Done. Power-cycle the board and remove BOOT_MODE jumpers if needed."),
            {ok, RState};
        _ ->
            warn("* uuu output:\n~s", [Out]),
            maybe_udev_hint(Out),
            abort("uuu reported an error", [])
    end.

maybe_udev_hint(Out) ->
    case (string:find(Out, "LIBUSB_ERROR_ACCESS") =/= nomatch) orelse
         (string:find(Out, "Permission denied") =/= nomatch) of
        true ->
            warn(
                "\nUSB permission error detected.\n" ++
                "Run `uuu -udev` once and follow its instructions to install a udev rule,\n" ++
                "then replug the board and retry.\n",
                []
            );
        false -> ok
    end.

% Script generation
% NOTE: This is a best-effort generic script that assumes a flash loader image
% (typically U-Boot with fastboot support) booted via ROM Serial Downloader.

gen_script(system) ->
    string:join([
        "uuu_version 1.4.149",
        "",
        "# Boot flash loader via ROM Serial Downloader",
        "SDP: boot -f flash_loader.bin -scanlimited 0x800000",
        "SDPS: boot -scanterm -f flash_loader.bin -scanlimited 0x800000",
        "SDPU: delay 1000",
        "SDPU: write -f flash_loader.bin -offset 0x57c00",
        "SDPU: jump -scanlimited 0x800000",
        "SDPV: delay 1000",
        "SDPV: write -f flash_loader.bin -skipspl -scanterm -scanlimited 0x800000",
        "SDPV: jump -scanlimited 0x800000",
        "",
        "# Configure fastboot for eMMC",
        "FB: ucmd setenv fastboot_buffer ${loadaddr}",
        "FB: ucmd setenv fastboot_dev mmc",
        "FB: ucmd setenv mmcdev 1",
        "FB: ucmd mmc dev 1",
        "",
        "# Download system partition image and write it to the first system partition",
        "# Layout assumptions (GRiSP2): 4MiB reserved area => start sector 8192 (0x2000)",
        "FB: download -f sys.img",
        "FB: ucmd setexpr blkcnt ${fastboot_bytes} + 0x1FF",
        "FB: ucmd setexpr blkcnt ${blkcnt} / 0x200",
        "FB: ucmd mmc write ${fastboot_buffer} 0x2000 ${blkcnt}",
        "",
        "FB: done"
    ], "\n");

gen_script(image) ->
    string:join([
        "uuu_version 1.4.149",
        "",
        "# Boot flash loader via ROM Serial Downloader",
        "SDP: boot -f flash_loader.bin -scanlimited 0x800000",
        "SDPS: boot -scanterm -f flash_loader.bin -scanlimited 0x800000",
        "SDPU: delay 1000",
        "SDPU: write -f flash_loader.bin -offset 0x57c00",
        "SDPU: jump -scanlimited 0x800000",
        "SDPV: delay 1000",
        "SDPV: write -f flash_loader.bin -skipspl -scanterm -scanlimited 0x800000",
        "SDPV: jump -scanlimited 0x800000",
        "",
        "# Configure fastboot for eMMC",
        "FB: ucmd setenv fastboot_buffer ${loadaddr}",
        "FB: ucmd setenv fastboot_dev mmc",
        "FB: ucmd setenv mmcdev 1",
        "FB: ucmd mmc dev 1",
        "",
        "# Download full image and write it to eMMC from sector 0",
        "FB: download -f emmc.img",
        "FB: ucmd setexpr blkcnt ${fastboot_bytes} + 0x1FF",
        "FB: ucmd setexpr blkcnt ${blkcnt} / 0x200",
        "FB: ucmd mmc write ${fastboot_buffer} 0x0 ${blkcnt}",
        "",
        "FB: done"
    ], "\n").
