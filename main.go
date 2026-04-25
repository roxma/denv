package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

type AllowEntry struct {
	Path  string `json:"path"`
	Ctime string `json:"ctime,omitempty"`
}

type Config struct {
	AllowList   []AllowEntry `json:"allow_list"`
	IgnoreEnvrc bool         `json:"ignore_envrc"`
}

func getConfigPath() string {
	if env := os.Getenv("DENV_CONFIG"); env != "" {
		return env
	}
	home := os.Getenv("HOME")
	if home == "" {
		panic("HOME not set")
	}
	return filepath.Join(home, ".config", "denv", "denv.json")
}

func loadConfig() Config {
	path := getConfigPath()
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return Config{}
	}
	for i, e := range cfg.AllowList {
		if strings.HasSuffix(e.Path, "/.denv") {
			cfg.AllowList[i].Path = filepath.Join(e.Path, "denv.bash")
		}
	}
	return cfg
}

func saveConfig(cfg Config) {
	path := getConfigPath()
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return
	}
	data, err := json.MarshalIndent(cfg, "", "    ")
	if err != nil {
		return
	}
	os.WriteFile(path, append(data, '\n'), 0644)
}

type denyReason int

const (
	allowed denyReason = iota
	notInList
	ctimeMismatch
)

func checkAllow(rc string, cfg Config) denyReason {
	if rc == "" {
		return allowed
	}
	for _, e := range cfg.AllowList {
		if e.Path == rc {
			current := getFileCtime(rc)
			if current != "" && e.Ctime == current {
				return allowed
			}
			return ctimeMismatch
		}
	}
	return notInList
}

func addAllow(rc string) {
	cfg := loadConfig()
	ctime := getFileCtime(rc)
	for i := range cfg.AllowList {
		if cfg.AllowList[i].Path == rc {
			cfg.AllowList[i].Ctime = ctime
			saveConfig(cfg)
			return
		}
	}
	cfg.AllowList = append(cfg.AllowList, AllowEntry{Path: rc, Ctime: ctime})
	saveConfig(cfg)
}

func removeAllow(rc string) {
	cfg := loadConfig()
	filtered := make([]AllowEntry, 0, len(cfg.AllowList))
	for _, e := range cfg.AllowList {
		if e.Path != rc {
			filtered = append(filtered, e)
		}
	}
	cfg.AllowList = filtered
	saveConfig(cfg)
}

func pruneAllow() {
	cfg := loadConfig()
	filtered := make([]AllowEntry, 0, len(cfg.AllowList))
	for _, e := range cfg.AllowList {
		if !pathExists(e.Path) {
			fmt.Printf("denv: filter non-existing [%s]\n", e.Path)
		} else {
			filtered = append(filtered, e)
		}
	}
	cfg.AllowList = filtered
	saveConfig(cfg)
}

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

func getCwd() string {
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	return cwd
}

func getParent(path string) string {
	path = filepath.Clean(path)
	if path == "/" {
		return ""
	}
	parent := filepath.Dir(path)
	if parent == path {
		return ""
	}
	return parent
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

func pathExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func findDenv(start string, ignoreEnvrc bool) string {
	d := start
	for {
		rc := filepath.Join(d, ".denv")
		if isDir(rc) {
			return filepath.Join(rc, "denv.bash")
		}
		rc = filepath.Join(d, ".denv.bash")
		if pathExists(rc) {
			return rc
		}
		if !ignoreEnvrc {
			rc = filepath.Join(d, ".envrc")
			if pathExists(rc) {
				return rc
			}
		}
		parent := getParent(d)
		if parent == "" || parent == d {
			return ""
		}
		d = parent
	}
}

func findAllDenv(start string, ignoreEnvrc bool) []string {
	var result []string
	d := start
	for {
		rc := filepath.Join(d, ".denv")
		if isDir(rc) {
			result = append(result, filepath.Join(rc, "denv.bash"))
		} else {
			rc = filepath.Join(d, ".denv.bash")
			if pathExists(rc) {
				result = append(result, rc)
			} else if !ignoreEnvrc {
				rc = filepath.Join(d, ".envrc")
				if pathExists(rc) {
					result = append(result, rc)
				}
			}
		}
		parent := getParent(d)
		if parent == "" || parent == d {
			break
		}
		d = parent
	}
	for i, j := 0, len(result)-1; i < j; i, j = i+1, j-1 {
		result[i], result[j] = result[j], result[i]
	}
	return result
}

func getFileCtime(rc string) string {
	path := rc
	if isDir(rc) {
		path = filepath.Join(rc, "denv.bash")
	}
	info, err := os.Stat(path)
	if err != nil {
		return ""
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ""
	}
	return fmt.Sprintf("%d.%09d", stat.Ctim.Sec, stat.Ctim.Nsec)
}

// ---------------------------------------------------------------------------
// Bash output
// ---------------------------------------------------------------------------

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'"
}

func formatSnippet(tmpl string, vars map[string]string) string {
	result := tmpl
	for k, v := range vars {
		result = strings.ReplaceAll(result, "{"+k+"}", v)
	}
	return result
}

const exitTemplate = `    echo "cd '$PWD'
    export OLDPWD='$OLDPWD'
    %s
    " > $DENV_TMP
    echo "denv: exit [$DENV_LOAD]"
    exit 0
`

func bashToParentEval(extra string) {
	fmt.Printf(exitTemplate, extra)
}

func getExePath() string {
	if path, err := os.Executable(); err == nil {
		return path
	}
	return "denv"
}

func currentDenv() string {
	load := os.Getenv("DENV_LOAD")
	if load == "" {
		return ""
	}
	parts := strings.Split(load, ":")
	return parts[len(parts)-1]
}

func getProjectDir(rc string) string {
	dir := getParent(rc)
	if filepath.Base(dir) == ".denv" {
		return getParent(dir)
	}
	return dir
}

func isOutOfScope(rc string) bool {
	cwd := getCwd()
	rcDir := getProjectDir(rc)
	if rcDir == "" {
		return true
	}
	return cwd != rcDir && !strings.HasPrefix(cwd, rcDir+"/")
}

func isDeeper(rc, current string) bool {
	rcDir := getProjectDir(rc)
	curDir := getProjectDir(current)
	if rcDir == "" || curDir == "" {
		return false
	}
	return rcDir != curDir && strings.HasPrefix(rcDir, curDir+"/")
}

const loadSnippet = `
if [ -n "$DENV_LOAD" -a -z "$denv_loaded" ]
then
    denv_loaded=1
    _denv_ifs="$IFS"
    IFS=':'
    for _denv_file in $DENV_LOAD; do
        echo "denv: loading [$_denv_file]"
        if [ -f "$_denv_file" ]
        then . "$_denv_file"
        else . "$_denv_file/denv.bash"
        fi
    done
    IFS="$_denv_ifs"
fi
denv_not_allowed=
`

const denySnippet = `
if [[ ":${denv_not_allowed}:" != *":{rc}:"* ]]
then
    tput setaf 3
    tput bold
    echo {msg}
    echo '       try execute "denv allow"'
    tput sgr0
    denv_not_allowed="${denv_not_allowed}:{rc}"
fi
`

const spawnSnippet = `
if [ "$(jobs)" == "" ]
then
    _denv_shell="${DENV_BASH:-$BASH}"
    echo "denv: spawn $_denv_shell"
    export DENV_TMP="$(mktemp "${TMPDIR-/tmp}/denv.XXXXXXXXXX")"
    DENV_LOAD={rc} DENV_PPID=$$ $_denv_shell
    eval "$(if [ -s $DENV_TMP ]; then cat $DENV_TMP; else echo exit 0; fi; rm $DENV_TMP)"
    unset DENV_TMP
    eval "$({exe} prompt {shell})"
else
    echo "denv: you have jobs, cannot load denv"
fi
`

func printDenyWarning(rc string, reason denyReason) {
	msg := "denv: [" + rc + "] NOT ALLOWED."
	if reason == ctimeMismatch {
		msg += " (file has changed since last allow, run 'denv allow' again)"
	}
	fmt.Print(formatSnippet(denySnippet, map[string]string{
		"rc":  shellQuote(rc),
		"msg": shellQuote(msg),
	}))
}

func doBashWrapped(shell string) {
	cfg := loadConfig()
	rcCur := currentDenv()
	allDenvs := findAllDenv(getCwd(), cfg.IgnoreEnvrc)

	var chain []string
	var denyList []string
	for _, rc := range allDenvs {
		if checkAllow(rc, cfg) == allowed {
			chain = append(chain, rc)
		} else {
			denyList = append(denyList, rc)
			break
		}
	}

	if rcCur != "" {
		if isOutOfScope(rcCur) {
			bashToParentEval("")
			return
		}

		for _, rc := range denyList {
			printDenyWarning(rc, checkAllow(rc, cfg))
		}

		for _, rc := range chain {
			if isDeeper(rc, rcCur) {
				bashToParentEval("")
				return
			}
		}

		fmt.Print(loadSnippet)
		return
	}

	if len(chain) > 0 {
		chainStr := strings.Join(chain, ":")
		exe := getExePath()
		fmt.Print(formatSnippet(spawnSnippet, map[string]string{
			"rc":    shellQuote(chainStr),
			"exe":   shellQuote(exe),
			"shell": shellQuote(shell),
		}))
		for _, rc := range denyList {
			printDenyWarning(rc, checkAllow(rc, cfg))
		}
		return
	}

	for _, rc := range denyList {
		printDenyWarning(rc, checkAllow(rc, cfg))
	}
}

func doPrompt(shell string) {
	// Strip leading dash used by login shells (e.g. "-bash")
	shell = strings.TrimPrefix(shell, "-")
	switch filepath.Base(shell) {
	case "bash", "sh":
		doBash(shell)
	default:
		fmt.Fprintf(os.Stderr, "unsupported shell: %s\n", shell)
		os.Exit(1)
	}
}

func doBash(shell string) {
	exe := getExePath()
	fmt.Println("{")
	fmt.Println("while :")
	fmt.Println("do")
	fmt.Println(` if [ -n "$DENV_PPID" -a "$DENV_PPID" != "$PPID" ]`)
	fmt.Println(" then")
	fmt.Println("  unset DENV_LOAD")
	fmt.Println("  unset DENV_PPID")
	fmt.Println("  unset DENV_TMP")
	fmt.Println("  unset denv_loaded")
	fmt.Println("  unset denv_not_allowed")
	fmt.Printf("  eval \"$(%s prompt %s)\"\n", shellQuote(exe), shellQuote(shell))
	fmt.Println("  break")
	fmt.Println(" fi")
	doBashWrapped(shell)
	fmt.Println("break")
	fmt.Println("done")
	fmt.Println("}")
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

func parentExe() string {
	ppid := os.Getppid()
	exe, err := os.Readlink(fmt.Sprintf("/proc/%d/exe", ppid))
	if err != nil {
		return ""
	}
	return filepath.Base(exe)
}

func printHelp() {
	fmt.Print(`denv 1.0.0
auto source .denv of your workspace

USAGE:
    denv [SUBCOMMAND]

SUBCOMMANDS:
    prompt   for bashrc: PROMPT_COMMAND='eval "$(denv prompt "$0")"'
    allow    Grant permission to denv to load the .denv
    deny     Remove the permission
    prune    Remove non-existing-file permissions
`)
}

func main() {
	if len(os.Args) < 2 {
		printHelp()
		os.Exit(0)
	}

	cmd := os.Args[1]
	switch cmd {
	case "prompt":
		shell := ""
		if len(os.Args) > 2 {
			shell = os.Args[2]
		} else {
			parent := parentExe()
			switch parent {
			case "bash", "sh":
				shell = parent
			default:
				if env := os.Getenv("SHELL"); env != "" {
					shell = env
				}
			}
		}
		doPrompt(shell)
	case "allow":
		cfg := loadConfig()
		allDenvs := findAllDenv(getCwd(), cfg.IgnoreEnvrc)
		if len(allDenvs) == 0 {
			fmt.Fprintln(os.Stderr, "No .denv found")
			os.Exit(1)
		}
		for _, rc := range allDenvs {
			addAllow(rc)
			fmt.Println("allowed:", rc)
		}
	case "deny":
		cfg := loadConfig()
		var path string
		if len(os.Args) > 2 {
			var err error
			path, err = filepath.EvalSymlinks(os.Args[2])
			if err != nil {
				fmt.Fprintf(os.Stderr, "Cannot resolve path: %s\n", os.Args[2])
				os.Exit(1)
			}
			if isDir(path) {
				path = findDenv(path, cfg.IgnoreEnvrc)
			}
		} else {
			path = findDenv(getCwd(), cfg.IgnoreEnvrc)
		}
		if path == "" {
			fmt.Fprintln(os.Stderr, "No .denv found")
			os.Exit(1)
		}
		removeAllow(path)
		fmt.Println(path + " is denied")
	case "prune":
		pruneAllow()
	default:
		printHelp()
		os.Exit(1)
	}
}
