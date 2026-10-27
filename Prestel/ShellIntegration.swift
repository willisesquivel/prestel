import Foundation

/// Zero-config shell integration. Prestel launches the login shell with a
/// small bootstrap that emits OSC 7 (cwd) and OSC 133 (prompt/command marks).
///
/// The scripts are embedded here and written to Application Support instead
/// of shipping as bundle resources: no Xcode resource plumbing, they work the
/// same under the test host, and the content is easy to assert on. Each
/// bootstrap sources the user's own startup files first (or lets the shell
/// read them natively), never edits them, and turns itself off when the user's
/// prompt already carries OSC 133 marks.
enum ShellIntegration {
    enum Shell: Equatable {
        case zsh, bash, fish
        init?(path: String) {
            switch URL(fileURLWithPath: path).lastPathComponent {
            case "zsh": self = .zsh
            case "bash": self = .bash
            case "fish": self = .fish
            default: return nil
            }
        }
    }

    struct Launch: Equatable {
        var arguments: [String] = []
        /// Whether argv[0] gets the leading dash that makes a shell a login shell.
        var isLogin = true
        var environment: [String: String]
    }

    /// Bump when a script changes so stale copies are rewritten.
    static let version = 2

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Prestel/ShellIntegration", isDirectory: true)
    }

    /// Written once per process; nil when the scripts could not be installed
    /// (read-only home, etc.), in which case shells start untouched.
    static let installedRoot: URL? = {
        let root = defaultRoot
        return install(into: root) ? root : nil
    }()

    static func launch(shell: String, environment: [String: String], root: URL?) -> Launch {
        var env = environment
        guard let root, let kind = Shell(path: shell) else { return Launch(environment: env) }
        env["PRESTEL_SHELL_INTEGRATION"] = "1"
        env["PRESTEL_SHELL_INTEGRATION_DIR"] = root.path
        switch kind {
        case .zsh:
            // A wrapper ZDOTDIR whose .zshenv restores the user's ZDOTDIR
            // straight away, so every later startup file (and /etc/zshrc's
            // HISTFILE) sees the real one.
            if let original = env["ZDOTDIR"] { env["PRESTEL_ORIG_ZDOTDIR"] = original }
            env["ZDOTDIR"] = root.appendingPathComponent("zsh").path
            return Launch(environment: env)
        case .bash:
            // A login bash ignores --rcfile, so start it as a plain interactive
            // shell; the rcfile replays the login startup files itself.
            return Launch(arguments: ["--rcfile", root.appendingPathComponent("bash/prestel.bash").path],
                          isLogin: false, environment: env)
        case .fish:
            let fallback = "/usr/local/share:/usr/share"
            let existing = env["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            env["XDG_DATA_DIRS"] = root.appendingPathComponent("fish-data").path + ":" + existing
            return Launch(environment: env)
        }
    }

    /// Idempotent. Rewrites a file only when its content differs.
    @discardableResult
    static func install(into root: URL) -> Bool {
        let files: [(String, String)] = [
            ("zsh/.zshenv", zshEnv),
            ("zsh/prestel-integration.zsh", zshIntegration),
            ("bash/prestel.bash", bashIntegration),
            ("fish-data/fish/vendor_conf.d/prestel.fish", fishIntegration),
        ]
        let manager = FileManager.default
        do {
            for (path, content) in files {
                let url = root.appendingPathComponent(path)
                let data = Data(content.utf8)
                if let existing = try? Data(contentsOf: url), existing == data { continue }
                try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    // MARK: - zsh

    static let zshEnv = #"""
    # Prestel shell integration bootstrap (version \#(version)). Restores your ZDOTDIR,
    # sources your own .zshenv, then loads the prompt hooks. Nothing of yours is modified.
    if [[ -n ${PRESTEL_ORIG_ZDOTDIR+x} ]]; then
      ZDOTDIR=$PRESTEL_ORIG_ZDOTDIR
      builtin unset PRESTEL_ORIG_ZDOTDIR
    else
      builtin unset ZDOTDIR
    fi
    if [[ -f ${ZDOTDIR:-$HOME}/.zshenv ]]; then
      builtin source -- "${ZDOTDIR:-$HOME}/.zshenv"
    fi
    if [[ -o interactive && -n ${PRESTEL_SHELL_INTEGRATION_DIR-} && -r $PRESTEL_SHELL_INTEGRATION_DIR/zsh/prestel-integration.zsh ]]; then
      builtin source -- "$PRESTEL_SHELL_INTEGRATION_DIR/zsh/prestel-integration.zsh"
    fi
    """#

    static let zshIntegration = #"""
    # Prestel shell integration for zsh: OSC 7 (cwd) and OSC 133 (prompt marks).
    [[ -o interactive ]] || return 0
    [[ ${PRESTEL_SHELL_INTEGRATION-} == 1 ]] || return 0
    (( ${+_prestel_loaded} )) && return 0
    typeset -g _prestel_loaded=1 _prestel_ran= _prestel_pwd= _prestel_off= _prestel_checked=

    _prestel_osc7() {
      [[ $PWD == "$_prestel_pwd" ]] && return
      _prestel_pwd=$PWD
      local LC_ALL=C i ch out=
      for (( i = 1; i <= ${#PWD}; i++ )); do
        ch=${PWD[i]}
        case $ch in
          [A-Za-z0-9/._~-]) out+=$ch ;;
          *) out+=$(printf '%%%02X' "'$ch") ;;
        esac
      done
      printf '\e]7;file://localhost%s\a' "$out"
    }

    # First in precmd_functions so $? is still the command's status.
    _prestel_pre() {
      local ret=$?
      [[ -n $_prestel_off ]] && return $ret
      if [[ -n $_prestel_ran ]]; then
        printf '\e]133;D;%d\a' $ret
        _prestel_ran=
      fi
      _prestel_osc7
      return $ret
    }

    # Last, so prompt frameworks that rebuild PS1 in their own precmd are covered.
    _prestel_post() {
      local ret=$?
      [[ -n $_prestel_off ]] && return $ret
      if [[ -z $_prestel_checked ]]; then
        _prestel_checked=1
        # The user's own setup already marks prompts: stay out of the way.
        if [[ $PS1 == *']133;'* ]] || (( ${+functions[iterm2_precmd]} )); then
          _prestel_off=1
          return $ret
        fi
      fi
      # cl=m: a click in the current command moves the caret with cursor keys.
      [[ $PS1 == *'133;A'* ]] || PS1=$'%{\e]133;A;cl=m\a%}'$PS1
      [[ $PS1 == *'133;B'* ]] || PS1=$PS1$'%{\e]133;B\a%}'
      precmd_functions=(${precmd_functions:#_prestel_post} _prestel_post)
      return $ret
    }

    _prestel_preexec() {
      [[ -n $_prestel_off ]] && return
      _prestel_ran=1
      printf '\e]133;C\a'
    }

    precmd_functions=(_prestel_pre $precmd_functions _prestel_post)
    preexec_functions+=(_prestel_preexec)
    """#

    // MARK: - bash

    static let bashIntegration = #"""
    # Prestel shell integration for bash (version \#(version)): OSC 7 and OSC 133.
    # Loaded with --rcfile, which bash only honours for non-login shells, so this
    # file replays what a login shell would have read. Your own files run unchanged.
    if [ -r /etc/profile ]; then builtin source /etc/profile; fi
    for __prestel_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [ -r "$__prestel_f" ]; then builtin source "$__prestel_f"; break; fi
    done
    builtin unset __prestel_f
    logout() { builtin exit "$@"; }

    if [[ $- == *i* && ${PRESTEL_SHELL_INTEGRATION-} == 1 && -z ${__prestel_loaded-} ]]; then
      __prestel_loaded=1 __prestel_ran= __prestel_pwd= __prestel_status=0 __prestel_busy=1

      __prestel_osc7() {
        [[ $PWD == "$__prestel_pwd" ]] && return
        __prestel_pwd=$PWD
        local LC_ALL=C i ch out=
        for (( i = 0; i < ${#PWD}; i++ )); do
          ch=${PWD:i:1}
          case $ch in
            [A-Za-z0-9/._~-]) out+=$ch ;;
            *) out+=$(printf '%%%02X' "'$ch") ;;
          esac
        done
        printf '\e]7;file://localhost%s\a' "$out"
      }

      # First in PROMPT_COMMAND so $? is still the command's status.
      __prestel_pre() {
        __prestel_status=$?
        __prestel_busy=1
        if [[ -n $__prestel_ran ]]; then
          printf '\e]133;D;%d\a' "$__prestel_status"
          __prestel_ran=
        fi
        __prestel_osc7
        return $__prestel_status
      }

      # Last, so prompts rebuilt by the user's PROMPT_COMMAND still get marks.
      __prestel_post() {
        # cl=m: a click in the current command moves the caret with cursor keys.
        [[ $PS1 == *'133;A'* ]] || PS1='\[\e]133;A;cl=m\a\]'$PS1
        [[ $PS1 == *'133;B'* ]] || PS1=$PS1'\[\e]133;B\a\]'
        __prestel_busy=
        return $__prestel_status
      }

      # DEBUG fires before each top-level command; the first one after a
      # prompt is the command the user typed.
      __prestel_debug() {
        [[ -n $__prestel_busy || -n $__prestel_ran ]] && return
        case $1 in __prestel_pre*) return ;; esac
        __prestel_ran=1
        printf '\e]133;C\a'
      }

      if [[ $PS1 == *']133;'* || ${PROMPT_COMMAND[*]-} == *']133;'* || $PS1 == *'133;A'* ]]; then
        builtin unset -f __prestel_osc7 __prestel_pre __prestel_post __prestel_debug
      else
        if [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
          PROMPT_COMMAND=(__prestel_pre "${PROMPT_COMMAND[@]}" __prestel_post)
        else
          PROMPT_COMMAND="__prestel_pre"$'\n'"${PROMPT_COMMAND-}"$'\n'"__prestel_post"
        fi
        # Without a DEBUG trap of our own there are no C/D marks, only A/B.
        if [[ -z $(builtin trap -p DEBUG) ]]; then
          builtin trap '__prestel_debug "$BASH_COMMAND"' DEBUG
        fi
      fi
    fi
    """#

    // MARK: - fish

    static let fishIntegration = #"""
    # Prestel shell integration for fish (version \#(version)): OSC 7 and OSC 133.
    status is-interactive; or return
    test "$PRESTEL_SHELL_INTEGRATION" = 1; or return
    set -q __prestel_loaded; and return
    set -g __prestel_loaded 1

    function __prestel_osc7 --on-event fish_prompt
        printf '\e]7;file://localhost%s\a' (string escape --style=url -- $PWD)
    end

    # fish 4 marks prompts natively.
    if test (string split . -- $version)[1] -lt 4
        function __prestel_mark_prompt --on-event fish_prompt
            # cl=m: a click in the current command moves the caret with cursor keys.
            printf '\e]133;A;cl=m\a'
        end
        function __prestel_mark_preexec --on-event fish_preexec
            printf '\e]133;C\a'
        end
        function __prestel_mark_postexec --on-event fish_postexec
            printf '\e]133;D;%d\a' $status
        end
    end
    """#
}

/// Adds `cl=m` to an OSC 133 prompt-start that did not ask for a click mode.
///
/// A shell that is already running keeps the script it sourced at startup.
/// That script emits `OSC 133 ; A` with no `cl=`, so a click never moves the
/// caret. Rewriting the mark as it arrives turns the click on for that shell
/// too. Marks that already name `cl=` or `click_events=1/2` are left alone.
struct PromptClickMarks {
    private enum Phase {
        case ground
        case esc
        case intro
        case code(Int)
        case body
        case bodyEsc
        case skip
        case skipEsc
    }

    private var phase = Phase.ground
    private var body: [UInt8] = []

    mutating func consume(_ input: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count + 8)
        for byte in input {
            consume(byte, into: &output)
        }
        return output
    }

    private mutating func consume(_ byte: UInt8, into output: inout [UInt8]) {
        switch phase {
        case .ground:
            if byte == 0x1b { phase = .esc }
            else { output.append(byte) }
        case .esc:
            if byte == 0x5d { phase = .intro }
            else {
                output.append(0x1b)
                output.append(byte)
                phase = .ground
            }
        case .intro:
            if let digit = Self.digit(byte) {
                phase = .code(digit)
            } else {
                output.append(contentsOf: [0x1b, 0x5d, byte])
                phase = Self.phase(afterPayloadByte: byte)
            }
        case .code(let code):
            if let digit = Self.digit(byte), code <= 100_000 {
                phase = .code(code * 10 + digit)
            } else if byte == 0x3b, code == 133 {
                body.removeAll(keepingCapacity: true)
                phase = .body
            } else if byte == 0x1b {
                emitIntro(code, into: &output)
                output.append(byte)
                phase = .skipEsc
            } else {
                emitIntro(code, into: &output)
                output.append(byte)
                phase = Self.phase(afterPayloadByte: byte)
            }
        case .body:
            if byte == 0x07 {
                emitPromptStart(body, terminator: [0x07], into: &output)
                phase = .ground
            } else if byte == 0x1b {
                phase = .bodyEsc
            } else if body.count >= 256 {
                emitPromptStart(body + [byte], terminator: [], into: &output)
                phase = .skip
            } else {
                body.append(byte)
            }
        case .bodyEsc:
            if byte == 0x5c {
                emitPromptStart(body, terminator: [0x1b, 0x5c], into: &output)
                phase = .ground
            } else {
                body.append(0x1b)
                phase = .body
                consume(byte, into: &output)
            }
        case .skip:
            output.append(byte)
            phase = Self.phase(afterPayloadByte: byte)
        case .skipEsc:
            output.append(byte)
            phase = byte == 0x5c ? .ground : .skip
        }
    }

    private func emitIntro(_ code: Int, into output: inout [UInt8]) {
        output.append(contentsOf: [0x1b, 0x5d])
        output.append(contentsOf: Array(String(code).utf8))
    }

    private func emitPromptStart(_ body: [UInt8], terminator: [UInt8], into output: inout [UInt8]) {
        output.append(contentsOf: [0x1b, 0x5d])
        output.append(contentsOf: Array("133;".utf8))
        output.append(contentsOf: clickable(body))
        output.append(contentsOf: terminator)
    }

    /// `A`, `N`, and `P` are the actions that install the click mode. A later
    /// prompt without `cl=` would clear a mode an earlier mark had set.
    private func clickable(_ body: [UInt8]) -> [UInt8] {
        guard let text = String(bytes: body, encoding: .utf8) else { return body }
        let fields = text.split(separator: ";", omittingEmptySubsequences: false)
        guard let action = fields.first, action.count == 1,
              action == "A" || action == "N" || action == "P" else { return body }
        let options = fields.dropFirst()
        if options.contains(where: { $0.hasPrefix("cl=") }) { return body }
        if options.contains(where: { $0 == "click_events=1" || $0 == "click_events=2" }) { return body }
        var updated = body
        updated.append(contentsOf: Array(";cl=m".utf8))
        return updated
    }

    private static func phase(afterPayloadByte byte: UInt8) -> Phase {
        if byte == 0x07 { return .ground }
        if byte == 0x1b { return .skipEsc }
        return .skip
    }

    private static func digit(_ byte: UInt8) -> Int? {
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        return Int(byte - 0x30)
    }
}
