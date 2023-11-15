#!/bin/bash -pe
#
# place a file called 'testapikey' in your current directory with the openai key you want to use for testing
# ensure gpt-cli.sh is executable and in PATH
#
export CHAT_BASEDIR=$(realpath -m testgptcli)
export COLOR_CHAT=false
export CURL_WAIT_CONNECT=30
export CURL_WAIT_COMPLETE=60
error() {
    # args: text...
    echo "$*" 1>&2
    return 1
}
explain_with_alias() {
    # args: prefix_text postfix_text thing [alias]
    if [[ -n "$4" ]]; then
        echo "$1 $4 ($3) $2" 1>&2
    else
        echo "$1 $3 $2" 1>&2
    fi
    return 1
}
assert_directory_exists() {
    # args: directory [alias]
    if [[ ! -d "$1" ]]; then
        explain_with_alias "directory" "should have existed" "$@"
    fi
}
assert_directory_notexists() {
    # args: directory [alias]
    if [[ -d "$1" ]]; then
        explain_with_alias "directory" "should not have existed" "$@"
    fi
}
assert_file_exists() {
    # args: file [alias]
    if [[ ! -f "$1" ]]; then
        explain_with_alias "file" "should have existed" "$@"
    fi
}
assert_file_notexists() {
    # args: file [alias]
    if [[ -f "$1" ]]; then
        explain_with_alias "file" "should not have existed" "$@"
    fi
}
assert_file_matches() {
    # args: egrep_pattern filename [alias]
    declare egrep_pattern=$1; shift
    if ! grep -qE "$egrep_pattern" "$1"; then
        explain_with_alias "file" "should have matched pattern ($egrep_pattern)" "$@"
    fi
}
assert_file_notmatches() {
    # args: egrep_pattern filename [alias]
    declare egrep_pattern=$1; shift
    if grep -qE "$egrep_pattern" "$1"; then
        explain_with_alias "file" "should have matched pattern ($egrep_pattern)" "$@"
    fi
}
assert_file_equals() {
    # args: expected_content filename [alias]
    declare expected_content=$1; shift
    if ! diff -qwB <(echo "$expected_content") "$1" >/dev/null; then
        explain_with_alias "file" "didn't match expected contents: $expected_content" "$@"
    fi
}
assert_text_matches() {
    # args: pattern text
    if ! { echo "$2" | grep -qE "$1" >/dev/null; }; then
        error "text didn't match expected pattern ($1): ($2)"
    fi
}
assert_text_notmatches() {
    # args: pattern text
    if { echo "$2" | grep -qE "$1" >/dev/null; }; then
        error "text matched pattern ($1): ($2)"
    fi
}
single_line_text() {
    # args: text
    # stdout: \r\n converted to spaces
    echo "$1" | tr -d '\r' | tr '\n' ' '
}
single_line_file() {
    # args: filename
    # stdout: content with \r\n converted to spaces
    single_line_text "$(<"$1")"
}
TEST_ID=1
start_test() { echo -n "$TEST_ID - ${1}: "; ((TEST_ID++)); }
end_test() { echo "ok"; }
q() {
    # args: arglist...
    # stdout: each argument quoted for consumption by the shell: foo'bar -> 'foo'\''bar'
    declare -a a i j=0 s="'\''"
    for i in "$@"; do a[$j]="'${i//\'/$s}'"; ((j++)); done
    echo "${a[*]}"
}
declare TEMPORARY_STDERR="$(mktemp)"
cleanup() { trap '' EXIT; rm -f "$TEMPORARY_STDERR"; exit 1; }
trap cleanup INT
trap cleanup EXIT
rungpt() {
    # save the current errexit setting
    shell_errexit=$(shopt -o -p errexit || true)
    CMD_STDOUT="" CMD_STDERR="" CMD_STATUS=""
    set +e
    CMD_STDOUT=$(gpt-cli.sh "$@" 2>"$TEMPORARY_STDERR")
    CMD_STATUS=$?
    CMD_STDERR=$(<"$TEMPORARY_STDERR")
    eval $shell_errexit; # restore
    if [[ $CMD_STATUS != "0" ]]; then error "gpt-cli.sh bad exit status: $CMD_STATUS"; fi
}

# not tested yet: -v | -S | -o instruction | -n prompt | - | @ | @<file>

start_test "verify environment setup"
    # verify that we can (probably) execute the command
    if ! command -v gpt-cli.sh &>/dev/null; then
        error "gpt-cli.sh is not available in PATH."
    fi
    # have an api key
    assert_file_exists "testapikey" "OPENAI-API-KEY"
    # target directory doesn't exist yet
    assert_directory_notexists "$CHAT_BASEDIR" "CHAT_BASEDIR"
end_test

start_test "basic initialization"
    rungpt -3 < testapikey
    assert_file_equals "CHAT_TOKEN not found in $CHAT_BASEDIR/settings." <(echo "$CMD_STDERR")
    assert_text_matches "Creating.*instructions" "$CMD_STDOUT"
    assert_text_matches "Creating.*assistant" "$CMD_STDOUT"
    assert_file_exists "$CHAT_BASEDIR/settings"
    assert_directory_exists "$CHAT_BASEDIR/instructions"
    assert_directory_exists "$CHAT_BASEDIR/chats"
    assert_directory_exists "$CHAT_BASEDIR/functions"
    assert_file_exists "$CHAT_BASEDIR/instructions/assistant"
    assert_file_exists "$CHAT_BASEDIR/functions/bash"
    assert_file_matches "^CHAT_MODEL='gpt-3.5-turbo'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_ID='default'\$" "$CHAT_BASEDIR/settings"
end_test

start_test "help options"
    rungpt --help
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "Arguments are evaluated in order" "$CMD_STDOUT"
    rungpt -help
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "Arguments are evaluated in order" "$CMD_STDOUT"
    rungpt -h
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "Arguments are evaluated in order" "$CMD_STDOUT"
    rungpt '-?'
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "Arguments are evaluated in order" "$CMD_STDOUT"
end_test

start_test "view settings"
    rungpt --settings
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "^CHAT_MODEL='gpt-3.5-turbo'\$" "$CMD_STDOUT"
end_test

start_test "instruction list"
    rungpt -I
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "^assistant\$" "$CMD_STDOUT"
end_test

start_test "model listing"
    rungpt --models gpt-4
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "gpt-4" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "specific model details"
    rungpt --model gpt-4
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches '"owner": "openai"' "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "set model gpt-4"
    rungpt -4
    assert_text_notmatches "." "$CMD_STDERR"
    assert_file_matches "^CHAT_MODEL='gpt-4'\$" "$CHAT_BASEDIR/settings"
end_test

start_test "set model gpt-4p"
    rungpt -4p
    assert_text_notmatches "." "$CMD_STDERR"
    assert_file_matches "^CHAT_MODEL='gpt-4-1106-preview'\$" "$CHAT_BASEDIR/settings"
end_test

start_test "set model gpt-3.5-turbo"
    rungpt -3
    assert_text_notmatches "." "$CMD_STDERR"
    assert_file_matches "^CHAT_MODEL='gpt-3.5-turbo'\$" "$CHAT_BASEDIR/settings"
end_test

start_test "create new chat 'default', with trailing parameters as prompt"
    assert_file_matches "^CHAT_ID='default'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_SUMMARY='gpt-3.5-turbo'\$" "$CHAT_BASEDIR/settings"
    rungpt --seed 1 what is 1 + 1
    assert_text_notmatches "." "$CMD_STDERR"
    assert_directory_exists "$CHAT_BASEDIR/chats/default"
    assert_file_exists "$CHAT_BASEDIR/chats/default/description"
    assert_text_matches "Initializing chat default from assistant 1 \+ 1 .*equal.* 2. Asking gpt-3.5-turbo to summarize this chat. \".*\"" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "chat directory"
    rungpt -d
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "/testgptcli/chats/default" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "chat listing: -l"
    rungpt -l
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "default +\[0+3\]: \"" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "chat listing: -ln"
    rungpt -l0
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "default +\[0+3\]: \"" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "create new chat 'test', test -c"
    rungpt --seed 1 -id test -c 'what is 1 + 2'
    assert_text_notmatches "." "$CMD_STDERR"
    assert_file_matches "^CHAT_ID='test'\$" "$CHAT_BASEDIR/settings"
    assert_directory_exists "$CHAT_BASEDIR/chats/test"
    assert_file_exists "$CHAT_BASEDIR/chats/test/description"
    assert_text_matches "Initializing chat test from assistant 1 \+ 2 .*equal.* 3. Asking gpt-3.5-turbo to summarize this chat. \".*\"" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "chat --list, test and default"
    rungpt --list
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "test +\[0+3\]: \"[^\"]*\" default +\[0+3\]: \"" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "chat --list=0, now test should be the top chat"
    rungpt --list=0
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "test +\[0+3\]: \"" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "show first entry"
    rungpt -s1
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "^0+1 - system: You are a helpful assistant. ===== $" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "show third entry"
    rungpt --show=3
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "^0+3 - assistant: 1 \+ 2 .*equal.* 3. ===== $" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "show last entry"
    rungpt --show=-1
    assert_text_notmatches "." "$CMD_STDERR"
    assert_text_matches "^0+3 - assistant: 1 \+ 2 .*equal.* 3. ===== $" "$(single_line_text "$CMD_STDOUT")"
end_test

start_test "test all the settings options"
    echo "be very helpful" > "$CHAT_BASEDIR/instructions/helpful"
    echo "be extra helpful" > "$CHAT_BASEDIR/instructions/helpful2"
    cp "$CHAT_BASEDIR/settings" "$CHAT_BASEDIR/settings.bak"
    rungpt -id test1 -max 100 -hist 100 -chatm test1 -sum test1.sum -instr helpful -set CHAT_TEMPERATURE 0.5 -set CHAT_KEEPDATA false -set URL_ENGINES testEngineURL -set URL_CHAT testChatURL
    assert_text_notmatches "." "$CMD_STDERR"
    assert_file_matches "^CHAT_MAXTOKENS='100'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_MODEL='test1'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_SUMMARY='test1.sum'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_HISTSIZE='100'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_ID='test1'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_INSTRUCTION='helpful'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_KEEPDATA='false'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^URL_ENGINES='testEngineURL'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^URL_CHAT='testChatURL'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_TEMPERATURE='0.5'\$" "$CHAT_BASEDIR/settings"
    cp "$CHAT_BASEDIR/settings" "$CHAT_BASEDIR/settings.test1"
    cp "$CHAT_BASEDIR/settings.bak" "$CHAT_BASEDIR/settings"
    rungpt --id test2 --max 200 --hist 200 --chatm test2 --sum test2.sum --instr helpful2 --set CHAT_TEMPERATURE 0.7 --set CHAT_KEEPDATA false --set URL_ENGINES test2EngineURL --set URL_CHAT test2ChatURL
    assert_text_notmatches "." "$CMD_STDERR"
    assert_file_matches "^CHAT_MAXTOKENS='200'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_MODEL='test2'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_SUMMARY='test2.sum'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_HISTSIZE='200'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_ID='test2'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_INSTRUCTION='helpful2'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_KEEPDATA='false'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^URL_ENGINES='test2EngineURL'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^URL_CHAT='test2ChatURL'\$" "$CHAT_BASEDIR/settings"
    assert_file_matches "^CHAT_TEMPERATURE='0.7'\$" "$CHAT_BASEDIR/settings"
    cp "$CHAT_BASEDIR/settings" "$CHAT_BASEDIR/settings.test2"
    cp "$CHAT_BASEDIR/settings.bak" "$CHAT_BASEDIR/settings"
end_test

echo "TESTS COMPLETED, to cleanup: rm -rf $(q "$CHAT_BASEDIR")"
