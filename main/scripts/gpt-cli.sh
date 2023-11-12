#!/bin/bash -p
# requires: bash, curl, jq, stdbuf, awk, sed, mkdir, ...
#
# TODO:
# allow -n# to take a number argument on how far back in the history to go
# make -s ranges work backwards: 1..3 (normal), 3..1 (reverse order)
# add an instruction (from a file or prompt for it?)
# for -o/--instr, if instruction starts with @ treat it as a file
# delete/archive/fork chat, Fork chat: -F newChatID from-sequence#
# ability to register arbitrary functions, enable/disable functions, etc
# per chat settings? engine, summary, histsize?
# per chat model histsize?
# need to handle a 'warning' element in response
# handle error status better:
#   {"error":{"code":503,"message":"Service Unavailable.","param":null,"type":"cf_service_unavailable"}}
#   {"error":{"message":"This model's maximum context length is 4097 tokens...","type":"invalid_request_error","param":"messages","code":"context_length_exceeded"}}
# Create image # POST https://api.openai.com/v1/images/generations
# Create image edit # POST https://api.openai.com/v1/images/edits
# Create image variation # POST https://api.openai.com/v1/images/variations
# Create embeddings # POST https://api.openai.com/v1/embeddings

# DEBUG LOAD: source <(sed -ne '/^#=====/,/^#=====/p' < chatgpt-cli.sh)
#====================================================================================================
#CHAT_HOMEDIR="$(realpath -e "$(dirname "${BASH_SOURCE[0]}")")"

# ENVIRONMENT:
CHAT_COMMAND_NAME="${0##*/}"
CHAT_BASEDIR="${CHAT_BASEDIR:-$HOME/.chat}"; # where do we store the chats
CURL_WAIT_CONNECT="${CURL_WAIT_CONNECT:-0}"; # curl --connect-timeout
CURL_WAIT_COMPLETE="${CURL_WAIT_COMPLETE:-0}"; # curl -w
if [[ -t 1 ]]; then
    COLOR_CHAT="${COLOR_CHAT:-true}"; # if we should output color codes or not
else
    COLOR_CHAT="false"
fi
CHAT_STDBUF="${CHAT_STDBUF:-"stdbuf"}"

# derived
CHATS="$CHAT_BASEDIR/chats"
INSTRUCTIONS="$CHAT_BASEDIR/instructions"
FUNCTIONS="$CHAT_BASEDIR/functions"
SETTINGS_FILE="$CHAT_BASEDIR/settings"

# per instance state (not saved)
CHAT_INSTRUCTION_FILE=""
CHAT_SEED="null"
CHAT_VERBOSE=false
CHAT_NOHIST=false; # default unless we do -n
CHAT_OVERRIDE_INSTRUCTION=""
CHAT_SUMMARIZE=false
CHAT_DIR=
CHAT_PATTERN='^(chat|asys)_[0-9]+_[0-9]+_(system|user|assistant)$'; # used to check if we have a valid chat filename
CHAT_TOKENS=0
CHAT_MESSAGES=()
CHAT_HISTORY=()

# the list of variables we will save in save_settings
declare -a user_properties=()
user_properties+=( 'CHAT_TOKEN' )
user_properties+=( 'CHAT_MAXTOKENS' )
user_properties+=( 'CHAT_MODEL' )
user_properties+=( 'CHAT_SUMMARY' )
user_properties+=( 'CHAT_HISTSIZE' )
user_properties+=( 'CHAT_ID' )
user_properties+=( 'CHAT_INSTRUCTION' )
user_properties+=( 'CHAT_KEEPDATA' )
user_properties+=( 'URL_ENGINES' )
user_properties+=( 'URL_CHAT' )
user_properties+=( 'CHAT_TEMPERATURE' )

if [[ -z "$CHAT_BASEDIR" ]]; then echo "CHAT_BASEDIR not set." 1>&2; exit 1; fi
mkdir -p -m 700 "$CHAT_BASEDIR" || exit 1
mkdir -p -m 700 "$FUNCTIONS" || exit 1
mkdir -p -m 700 "$CHATS" || exit 1

#notused
p() { declare -n arr="$1"; echo "${arr[@]}"; }

q() {
    # args: arglist...
    # stdout: each argument quoted for consumption by the shell: foo'bar -> 'foo'\''bar'
    declare -a a i j=0 s="'\''"
    for i in "$@"; do a[$j]="'${i//\'/$s}'"; ((j++)); done
    echo "${a[*]}"
}

show_settings() {
    # stdout: all the properties listed in user_properties in a BASH compatible format
    # this isn't bullet proof but should be good enough for basic settings, but maybe not setuid safe
    # but variables can at least have quotes in them without breaking it
    for prop in "${user_properties[@]}"; do declare -n pv="${prop}"; echo "${prop}=$(q "${pv}" )"; done
}

save_settings() {
    # write the settings out to the SETTINGS_FILE
    show_settings > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
}

load_settings() {
    # load user settings data with defaulting, helps to bootstrap the system
    # since CHAT_TOKEN is required we will prompt the user for it if it doesn't exist
    declare save=false
    if [[ -f "$SETTINGS_FILE" ]]; then source "${SETTINGS_FILE}"; fi
    if [[ -z "$CHAT_TOKEN" ]]; then
        error '%s\n' "CHAT_TOKEN not found in ${SETTINGS_FILE}." 1>&2
        read -r -p "Please enter your OpenAI Token (starting with sk-): " CHAT_TOKEN
        save=true
    fi
    if [[ -z "$CHAT_MAXTOKENS" ]]; then CHAT_MAXTOKENS="null"; save=true; fi
    if [[ -z "$CHAT_ID" ]]; then CHAT_ID="default"; save=true; fi
    if [[ -z "$CHAT_INSTRUCTION" ]]; then CHAT_INSTRUCTION="assistant"; save=true; fi
    if [[ -z "$CHAT_KEEPDATA" ]]; then CHAT_KEEPDATA="true"; save=true; fi
    if [[ -z "$CHAT_HISTSIZE" ]]; then CHAT_HISTSIZE="1000"; save=true; fi
    if [[ -z "$CHAT_MODEL" ]]; then CHAT_MODEL="gpt-4"; save=true; fi
    if [[ -z "$CHAT_SUMMARY" ]]; then CHAT_SUMMARY="gpt-3.5-turbo"; save=true; fi
    if [[ -z "$URL_ENGINES" ]]; then URL_ENGINES="https://api.openai.com/v1/engines"; save=true; fi
    if [[ -z "$URL_CHAT" ]]; then URL_CHAT="https://api.openai.com/v1/chat/completions"; save=true; fi
    if [[ -z "$CHAT_TEMPERATURE" ]]; then CHAT_TEMPERATURE="null"; save=true; fi
    #URL_COMPLETE="https://api.openai.com/v1/completions" #deprecated
    set_instruction
    [[ "$save" == "true" ]] && save_settings
}

exists_in() {
    # args: propertyValue arglist...
    # return: 0 = found, 1 = not found
    declare propertyValue="$1"; shift
    declare element
    for element in "$@"; do
       if [[ "$element" == "$propertyValue" ]]; then
           return 0
       fi
    done
    return 1
}

cprintf() { declare code="$1" fmt="$2"; shift 2; [[ "$COLOR_CHAT" == "true" ]] && printf "\033[${code}m${fmt}\033[0m" "$@" || printf "${fmt}" "$@"; }
bold() { cprintf 1 "$@"; }
underline() { cprintf 4 "$@"; }
black() { cprintf 30 "$@"; }
red() { cprintf 31 "$@"; }
green() { cprintf 32 "$@"; }
yellow() { cprintf 33 "$@"; }
blue() { cprintf 34 "$@"; }
magenta() { cprintf 35 "$@"; }
cyan() { cprintf 36 "$@"; }
grey() { cprintf 37 "$@"; }
darkgrey() { cprintf 90 "$@"; }
lightred() { cprintf 91 "$@"; }
lightgreen() { cprintf 92 "$@"; }
lightyellow() { cprintf 93 "$@"; }
lightblue() { cprintf 94 "$@"; }
lightmagenta() { cprintf 95 "$@"; }
lightcyan() { cprintf 96 "$@"; }
white() { cprintf 97 "$@"; }

error() { red "$@"; }
warning() { yellow "$@"; }
info() { green "$@"; }
title() { magenta "$@"; }
debug() { magenta "$@"; }
label() { cyan "$@"; }
trace() { darkgrey "$@"; }
aux() { blue "$@"; }

cleanup() { white ''; }
trap cleanup INT
trap cleanup EXIT

pick_sequence() {
    # args: inArrayName outArrayName start end
    declare -n inArray="$1"
    declare -n outArray="$2"
    declare start=$3 end=$4 size=${#inArray[@]} i
    [[ -z $start ]] && start=1
    [[ -z $end ]] && end=$size
    [[ $start -lt 0 ]] && start=$((size + start + 1))
    [[ $end -lt 0 ]] && end=$((size + end + 1))
    start=$(( start < 1 ? 1 : start ))
    end=$(( end > size ? size : end ))
    for ((i=start; i<=end; i++)); do
        outArray+=( "${inArray[i-1]}" )
    done
}

pick_range() {
    # args: inArrayName outArrayName rangeSpec
    declare inArrayName="$1" outArrayName="$2" range="$3"
    declare -n arr="$inArrayName"
    declare endof="${#arr[@]}"
    IFS=, read -ra ranges <<< "$range"
    for r in "${ranges[@]}"; do
        if [[ $r == ..* ]]; then r="1${r}"; fi
        if [[ $r == *.. ]]; then r="${r}${endof}"; fi
        if [[ $r == *..* ]]; then
            IFS='..' read -ra bounds <<< "$r"
            pick_sequence "$inArrayName" "$outArrayName" "${bounds[0]}" "${bounds[2]}"
        else
            pick_sequence "$inArrayName" "$outArrayName" "$r" "$r"
        fi
    done
}

test_pick_range() {
    declare -a testcases=(
        '1'         'one'
        '3..'       'three four five'
        '-3..'      'three four five'
        '..10'      'one two three four five'
        '..-3'      'one two three'
        '2..4'      'two three four'
        '3,1,5'     'three one five'
        '-2..-1,1'  'four five one'
    )
    declare -a itemlist=( one two three four five )
    declare i
    for ((i=0; i<${#testcases[@]}; i+=2)); do
        declare theRange=${testcases[i]}
        declare expected=${testcases[i+1]}
        declare -a outlist=()
        pick_range itemlist outlist "$theRange"
        got="${outlist[*]}"
        if [[ "$got" = "$expected" ]]; then
            echo "pick_range itemlist a \"$theRange\" -> $got"
        else
            echo "FAILED: testcase for '$theRange' expecting ($expected) got $got"
            return 1;
        fi
    done
    return 0
}

# gpt-3.5-turbo, gpt-3.5-turbo-16k, gpt-4, gpt-4-1106-preview, gpt-4-vision-preview, gpt-3.5-turbo-1106
list_models() {
    # args: jqContainsPattern(default:'gpt')
    # stdout: list of gpt engine names that matched the pattern
    declare pattern="${1:-gpt}"
    curl -sS -H "Authorization: Bearer ${CHAT_TOKEN}" "${URL_ENGINES}" | jq --arg pattern "${pattern}" -r '.data[] | select(.id | contains($pattern)) | .id'
}

get_model() {
    # args: gptModelName(default:'gpt-4')
    # stdout: json model results
    declare model="${1:-gpt-4}"
    curl -sS -H "Authorization: Bearer ${CHAT_TOKEN}" "${URL_ENGINES}/${model}"
}

#notused
tagline() {
    # args: matchstring
    # stdin: text lines
    # stdout: input lines with any line matching 'matchstring' exactly has ' *' appended
    awk -v find="$1" '{ if ($0 == find) print $0 " *"; else print; }'
}

removeline() {
    # args: deletestring
    # stdin: text lines
    # stdout: input lines minus any matching 'deletestring'
    awk -v find="$1" '{ if ($0 != find) print; }'
}

detail_chat() {
    # args: chatID
    # stdout: chatID [chatCount]: chatDescription
    declare -i width=40
    if [[ "$COLOR_CHAT" == "true" ]]; then width+=9; fi; # allow for formatting characters
    declare count=$(get_sequence_number "$1")
    declare descfile="$CHATS/$1/description"
    declare desctext="untitled"
    if [[ -f "$descfile" ]]; then
        desctext=$(<"$descfile")
    fi
    printf "%-${width}s [%04d]: %s\n" "$(label '%s' "${1}")" "$count" "$(title '%s' "$desctext")"
}

list_recent_chats() {
    # args: number
    # stdout: list of chats (via detail_chat)
    declare filename
    while IFS= read -r filename; do
        detail_chat "$filename"
    done < <(
        echo "$CHAT_ID";
        ls -A1t "$CHATS" | grep -v '^_$' | grep -v '^\.' | removeline "$CHAT_ID" | head -n "$1"
    )
}

list_instructions() {
    # stdout: list of instruction files
    while IFS= read -r filename; do
        warning '%s\n' "$filename"
    done < <(
        ls -A1 "$INSTRUCTIONS"
    )
}

token_estimate() {
    # stdin: content
    # stdout: estimated token count
    # just a swag at the number of words plus non-word characters
    awk '{ gsub(/[a-zA-Z]+/, "X"); gsub(/[ \t\r\n]+/, ""); n += length($0); } END { print n }'
}

tojsonlist() {
    # args: function_file ...
    # stdout: json array of combined file contents
    echo "["
    declare index=1
    declare last_index=$#
    for file in "$@"; do
        if [[ $index -ne $last_index ]]; then
            cat "$file"
            echo ","
        else
            cat "$file"
        fi
        ((index++))
    done
    echo "]"
}

build_chat_completion() {
    # args: role1 prompt1 role2 prompt2 ...
    # stdout: built chat completion JSON request object
    #trace '%s\n' "DEBUG build_chat_completion: $*" 1>&2

    # for lots of history messages this could be a lot of jq invocations
    # at some point it might make sense to save each json fragment
    declare i j msgs=()
    for ((i=1; i<=$#; i+=2)); do
        ((j=i+1))
        msgs+=("$(jq -cn --arg r "${!i}" --arg c "${!j}" '{role: $r, content: $c}')")
    done

    #TODO: need to figure out how to load functions dynamically and also have none
    #TODO: for now we have one function hardcodded as a proof of concept
    declare functions
    functions="$(tojsonlist "$FUNCTIONS/bash")"

    jq -n \
      --arg model "$CHAT_MODEL" \
      --argjson max_tokens "$CHAT_MAXTOKENS" \
      --argjson temperature "$CHAT_TEMPERATURE" \
      --argjson seed "$CHAT_SEED" \
      --argjson funcs "$functions" \
      --argjson msgs "$(echo "${msgs[*]}" | jq -s .)" \
      '{
          model: $model,
          stream: true,
          messages: $msgs,
          functions: $funcs
      }
      + (if $seed != null then {seed: $seed} else {} end)
      + (if $temperature != null then {temperature: $temperature} else {} end)
      + (if $max_tokens != null then {max_tokens: $max_tokens} else {} end)'
}

chat_completion() {
    # args: json_request
    # stdout: the API JSON stream
    # execute a chat completion via curl
    $CHAT_STDBUF -oL curl -N "$URL_CHAT" -sS -XPOST --connect-timeout "$CURL_WAIT_CONNECT" -m "$CURL_WAIT_COMPLETE" \
        -H "Authorization: Bearer ${CHAT_TOKEN}" \
        -H "Content-type: application/json" -d "$1"
}

# nobody will ever need mnore than 6 decimal digits for a chat...
numfmt() { printf "%06d" "$1"; }

splitfilename() {
    # args: arrayRef filename
    # filename expected to contain: tag_sequence#_tokenCount_role
    # split an asys or chat filename into parts
    declare -n return_array="$1"
    declare filename="$2"
    IFS="_" read -ra return_array <<< "$filename"
}

show_chat() {
    # args: show_ranges
    # stdout: dump out chat history
    declare chat_directory="$CHATS/$CHAT_ID"
    declare show_ranges="${1:-'1..-1'}"
    declare nullglob_was_set=$(shopt -p nullglob)  # Save the state of nullglob
    if [[ -d "$chat_directory" ]]; then
        shopt -s nullglob  # Temporarily turn on nullglob
        readarray -t chatfiles < <(printf '%s\n' "${chat_directory}"/{asys*,chat*})

        # to map from a number to the actual chat data, some sequence# might not exist
        declare -A chatpart_file
        declare -A chatpart_seq
        declare -A chatpart_role
        for filepath in "${chatfiles[@]}"; do
            splitfilename parts "${filepath##*/}"
            sequence_num=$((10#${parts[1]}))
            ((sequence_num > last_sequence)) && last_sequence=$sequence_num
            chatpart_file[$sequence_num]="$filepath"
            chatpart_seq[$sequence_num]="${parts[1]}"
            chatpart_role[$sequence_num]="${parts[3]}"
        done

        declare -a chat_sequence=()
        for ((i=1; i<=last_sequence; i++)); do chat_sequence+=("$i"); done

        declare -a picked_sequence=()
        pick_range chat_sequence picked_sequence "$show_ranges"
        for chatkey in "${picked_sequence[@]}"; do
            if [[ -n "${chatpart_file[$chatkey]}" ]]; then
                label '%s\n' "${chatpart_seq[$chatkey]} - ${chatpart_role[$chatkey]}:"
                echo "$(< "${chatpart_file[$chatkey]}")"
                darkgrey '%s\n' "====="
            fi
        done

        eval "$nullglob_was_set"  # Restore the original state of nullglob
    else
        error '%s\n' "Chat $CHAT_ID does not exist"
    fi
}

sequence=1
incseq() { ((sequence++)); }

make_chat_filename() {
    # args: tag sequence tokens role
    # stdout: full path to a chat file
    #trace '%s\n' "DEBUG: make_chat_filename = $*" 1>&2
    echo "${CHAT_DIR}/${1}_$(numfmt "${2}")_$(numfmt "${3}")_${4}"
}

jq_stream_complete() {
    # args:
    # stdin: openai chat json stream
    # stdout: unbuffered stream of decoded json content
    $CHAT_STDBUF -oL sed -e '/^$/d; /^data: \[DONE]/d; s/data: //' | \
    $CHAT_STDBUF -o0 jq -j 'select(.choices[].index == 0) | if .choices[].delta.content then .choices[].delta.content // "" else .choices[].delta.function_call.arguments // "" end'
}

analyze_results() {
    # args:
    # stdin: openai chat json stream
    # stdout: role\nfinish_reason\nfunctionName\ntokenCount\n
    # scan through openai api stream output and extract: role, finish_reason, function_name, and tokenCount
    # values will be 'null' if empty
    sed -e '/^$/d; /^data: \[DONE]/d; s/data: //' | \
    jq -nj '
      reduce (inputs | select(.choices[].index == 0)) as $record (
        {"role": null, "finish_reason": null, "function_call_name": null, "count": 0};
        .count += 1 |
        .role               = if .role               == null and ($record.choices[0].delta | has("role"))          then $record.choices[0].delta.role               else .role               end |
        .finish_reason      = if .finish_reason      == null and ($record.choices[0]       | has("finish_reason")) then $record.choices[0].finish_reason            else .finish_reason      end |
        .function_call_name = if .function_call_name == null and ($record.choices[0].delta | has("function_call")) then $record.choices[0].delta.function_call.name else .function_call_name end
      ) | "\(.role)\n\(.finish_reason)\n\(.function_call_name)\n\(.count)\n"
    '
}

install_instruction() {
    # copy currently selected CHAT_INSTRUCTION into the chat
    declare sys_tokens
    sys_tokens="$(token_estimate < "$CHAT_INSTRUCTION_FILE")"; # TODO: just a rough estimate for now
    cp "$CHAT_INSTRUCTION_FILE" "$(make_chat_filename asys 1 "$sys_tokens" system)"
}

set_instruction() {
    # args: instruction_@file_or_reference
    CHAT_INSTRUCTION=${1:-"$CHAT_INSTRUCTION"}
    if [[ "$CHAT_INSTRUCTION" =~ ^@ ]]; then
        CHAT_INSTRUCTION_FILE="${CHAT_INSTRUCTION#@}"
    else
        CHAT_INSTRUCTION_FILE="$INSTRUCTIONS/$CHAT_INSTRUCTION"
    fi
    if [[ ! -f "$CHAT_INSTRUCTION_FILE" ]]; then
        warning '%s\n' "Instruction file $(q "$CHAT_INSTRUCTION") is missing." 1>&2
        #exit 1
    fi
}

add_prompt() {
    # args: target(-h|-m) token_count role content
    CHAT_TOKENS=$(( CHAT_TOKENS + 10#"$2" ))
    if [[ $CHAT_TOKENS -le $CHAT_HISTSIZE ]]; then
        # we only actually add the chat content if it will fit
        if [[ "$1" == "-m" ]]; then
            # forward order
            CHAT_MESSAGES+=( "$3" )
            CHAT_MESSAGES+=( "$4" )
        else
            # reverse order
            CHAT_HISTORY+=( "$4" )
            CHAT_HISTORY+=( "$3" )
        fi
        return 0
    else
        # history is full
        if [[ "$1" == "-h" ]]; then
            #trace '%s\n' "DEBUG: history buffer is full at $CHAT_TOKENS vs $CHAT_HISTSIZE" 1>&2
            return 1
        else
            warning '%s\n' "Warning: History size ($CHAT_HISTSIZE tokens) was too small for system messages ($CHAT_TOKENS tokens)" 1>&2
            return 0
        fi
    fi
    # not reached
}

add_prompt_from_files() {
    # args: target(-h|-m) filenames...
    declare -a parts
    declare target="$1"; shift
    declare filepath
    declare filename
    declare content

    for fn in "$@"; do
        if [[ "$fn" =~ ^/ ]]; then
            filepath="$fn"
            filename="$(basename "$fn")"
        else
            filepath="${CHAT_DIR}/$fn"
            filename="$fn"
        fi
        IFS= read -rd '' content <"$filepath"
        if [[ "$filename" =~ $CHAT_PATTERN ]]; then
            splitfilename parts "$fn"; # tag_seq#_tok#_role
            add_prompt "$target" "${parts[2]}" "${parts[3]}" "$content" || break
        else
            # intended use is for instruction override
            add_prompt "$target" "$(token_estimate <<< "$content")" system "$content" || break
        fi
    done
}

get_sequence_number() {
    # args: chatID
    # stdout: next chat sequence number, defaults to 1
    declare chat_directory="${CHATS}/$1"
    declare last_sequence=0  # Assume no sequence files to start with
    declare filename parts sequence_num
    declare nullglob_was_set=$(shopt -p nullglob)  # Save the state of nullglob
    if [[ -d "$chat_directory" ]]; then
        shopt -s nullglob  # Temporarily turn on nullglob
        for filepath in "$chat_directory"/chat_*; do
            splitfilename parts "${filepath##*/}"
            sequence_num=$((10#${parts[1]}))
            ((sequence_num > last_sequence)) && last_sequence=$sequence_num
        done
        eval "$nullglob_was_set"  # Restore the original state of nullglob
    fi
    echo -n $last_sequence
}

get_next_sequence_number() {
    # args: chatID
    # stdout: next chat sequence number, defaults to 1
    echo -n $(( $(get_sequence_number "$1") + 1 ))
}

initialize_chat_dir() {
    # return true if new chat
    CHAT_DIR="$CHATS/$CHAT_ID"
    CHAT_MESSAGES=()
    CHAT_HISTORY=()
    CHAT_TOKENS=0
    if [[ ! -d "$CHAT_DIR" ]]; then
        mkdir -p -m 700 "$CHAT_DIR"
        info '%s\n' "Initializing chat ${CHAT_ID} from $CHAT_INSTRUCTION"
        install_instruction
        sequence=2
        add_prompt_from_files -m "$CHAT_INSTRUCTION_FILE"
        return 0
    fi
    return 1
}

handle_finish_reason() {
    declare finish_reason="$1"
    declare contentfile="$2"
    declare function_name="$3"
    declare completion_tokens="$4"

    if [[ $CHAT_VERBOSE == "true" ]]; then
        aux '\n%s\n' "[${finish_reason}:${completion_tokens}]"
    fi

    case $finish_reason in
        stop)
        ;;
        function_call)
            declare command_string
            IFS= read -rd '' command_string < <(jq -r '[.command] | @sh' <"$contentfile")
            info '%s\n' "FUNCTION ${function_name}: $command_string"
        ;;
        *)
            error '%s\n' "BAD JSON RESPONSE: $json_responsefile" 1>&2
            grep '"message":' "$json_responsefile" 1>&2
            exit 1
        ;;
    esac
}

select_history_files() {
    # We have two options to deal with:
    #     CHAT_OVERRIDE_INSTRUCTION -- load from an instruction file and skip asys_*_system
    #     CHAT_NOHIST               -- do not load *_user chat files
    if [[ "$CHAT_OVERRIDE_INSTRUCTION" == "" ]]; then
        if [[ "$CHAT_NOHIST" == "true" ]]; then
            # asys_* minus *_user
            ls -A1f "${CHAT_DIR}" | grep '^asys_' | grep -v '_user$' | sort -V
        else
            # asys_*
            ls -A1f "${CHAT_DIR}" | grep '^asys_' | sort -V
        fi
    else
        # load the CHAT_OVERRIDE_INSTRUCTION instead of the chat instruction
        echo "$CHAT_OVERRIDE_INSTRUCTION"
        if [[ "$CHAT_NOHIST" != "true" ]]; then
            # asys_* minus *_system
            ls -A1f "${CHAT_DIR}" | grep '^asys_' | grep -v '_system$' | sort -V
        fi
    fi
}

do_chat() {
    # args: prompt
    # stdout: chat completion output
    # now that this is working smoothly we can work on refactoring
    declare prompt="$1"
    declare tag="chat"
    if initialize_chat_dir; then
        tag="asys"
    else
        declare -a sysfiles
        readarray -t sysfiles < <(select_history_files)
        add_prompt_from_files -m "${sysfiles[@]}"
    fi

    # reverse order is for the token counting
    declare -a chatfiles
    readarray -t chatfiles < <(ls -A1f "${CHAT_DIR}" | grep '^chat' | sort -Vr)
    #trace '%s\n' "DEBUG: chatfiles = ${chatfiles[*]}" 1>&2
    if [[ "${#chatfiles[@]}" -gt 0 ]]; then
        # figure out where we are in the sequence
        lastchat="${chatfiles[0]}"; # first one in the list is most recent
        splitfilename parts "$lastchat"
        sequence=$((10#${parts[1]})); incseq
        #trace '%s\n' "DEBUG: adding to chat, sequence=$sequence, lastchat split = ${parts[*]}" 1>&2

        if [[ "$CHAT_NOHIST" != "true" ]]; then
            # load in our history chat
            add_prompt_from_files -h "${chatfiles[@]}"
        fi
    else
        sequence=2
    fi

    # add CHAT_HISTORY into CHAT_MESSAGES in reverse so the oldest are now first
    declare len="${#CHAT_HISTORY[@]}"
    for ((i=len-1; i>=0; i--)); do
        CHAT_MESSAGES+=( "${CHAT_HISTORY[i]}" )
    done

    # now add in the current prompt
    CHAT_MESSAGES+=( "user" "$prompt" )

    declare json_request="$(build_chat_completion "${CHAT_MESSAGES[@]}")"
    declare json_requestfile="$(make_chat_filename json "$sequence" 0 request)"
    echo "$json_request" > "$json_requestfile"

    declare json_responsefile="$(make_chat_filename json "$((sequence+1))" 0 response)"
    declare contentfile="${CHAT_DIR}/.content"

    if [[ $CHAT_VERBOSE == "true" ]]; then
        label '%s - %s:\n' "$(numfmt "$sequence")" "user"
    fi

    chat_completion "$json_request" | $CHAT_STDBUF -oL tee "$json_responsefile" | jq_stream_complete | $CHAT_STDBUF -i0 -o0 tee "$contentfile"
    echo ""

    declare -a status=( "${PIPESTATUS[@]}" )
    [[ "${status[*]}" =~ [^0\ ] ]] && error '%s\n' "Failed return status from chat pipeline: ${status[*]}" 1>&2

    declare -a chat_status
    readarray -t chat_status < <(analyze_results < "$json_responsefile")
    declare role="${chat_status[0]}"
    declare finish_reason="${chat_status[1]}"
    declare function_name="${chat_status[2]}"
    declare completion_tokens="${chat_status[3]}"

    handle_finish_reason "$finish_reason" "$contentfile" "$function_name" "$completion_tokens"

    declare est_prompt_tokens="$(token_estimate <<< "$prompt")"
    declare promptfile="$(make_chat_filename "$tag" "$sequence" "$est_prompt_tokens" user)"; incseq
    echo "$prompt" > "$promptfile"; # save the prompt text

    declare chatfile="$(make_chat_filename chat "$sequence" "$completion_tokens" "$role")";
    mv "$contentfile" "$chatfile"; # save the response text

    # summarize if needed
    if [[ "$CHAT_SUMMARIZE" == "true" ]] || [[ ! -f "$CHAT_DIR/description" ]]; then
        info '%s\n' "Asking $CHAT_SUMMARY to summarize this chat."
        declare content
        IFS= read -rd '' content <"$chatfile"
        CHAT_MESSAGES+=( "$role" "$content" )
        CHAT_MESSAGES+=( "user" "Write a very short summary of the chat so far to be used as a title, placed in double-quotes." )
        KEEPFILE_SUMMARY_REQEUST="${CHAT_DIR}/.summary.request"
        KEEPFILE_SUMMARY_RESPONSE="${CHAT_DIR}/.summary.response"
        build_chat_completion "${CHAT_MESSAGES[@]}" > "$KEEPFILE_SUMMARY_REQEUST"
        chat_completion "$(build_chat_completion "${CHAT_MESSAGES[@]}")" | tee "$KEEPFILE_SUMMARY_RESPONSE" | jq_stream_complete | $CHAT_STDBUF -i0 -o0 tee "$CHAT_DIR/description"
        echo ""
        if [[ "$CHAT_KEEPDATA" != "true" ]]; then
            rm -f "$KEEPFILE_SUMMARY_REQEUST" "$KEEPFILE_SUMMARY_RESPONSE"
        fi
    fi

    if [[ "$CHAT_KEEPDATA" != "true" ]]; then
        rm -f "$json_requestfile" "$json_responsefile"
    fi
}
#====================================================================================================

# bootstrap instructions if needed
if [[ ! -d "$INSTRUCTIONS" ]]; then
    info '%s\n' "Creating $INSTRUCTIONS"
    mkdir -p -m 700 "$INSTRUCTIONS" || exit 1
    if [[ ! -f "$INSTRUCTIONS/assistant" ]]; then
        info '%s\n' "Creating ${INSTRUCTIONS}/assistant"
        echo "You are a helpful assistant." > "$INSTRUCTIONS/assistant"
    fi
fi

load_settings

# bootstrap the bash sample function
if [[ ! -f "$FUNCTIONS/bash" ]]; then
    cat > "$FUNCTIONS/bash" << 'EOF'
{
  "name": "bash",
  "description": "Execute bash code on the remote agent when asked to write a bash script.",
  "parameters": {
    "type": "object",
    "properties": {
      "command": {
        "description": "The bash shell commands to execute.",
        "type": "string"
      }
    },
    "required": [
      "command"
    ]
  }
}
EOF
fi

usage() {
    echo "${CHAT_COMMAND_NAME} [options] [prompt]"
    echo '    --help|-h|-?                 - print usage and exit'
    echo '    --sett*                      - settings: output settings'
    echo '    --id chatID                  - settings: set current chat id (CHAT_ID)'
    echo '    --set property value         - settings: set a property (CHAT_TEMPERATURE, CHAT_KEEPDATA, URL_ENGINES, URL_CHAT)'
    echo '    --to* api-token              - settings: set api token (CHAT_TOKEN)'
    echo '    --max* #tokens               - settings: set max token limit (CHAT_MAXTOKENS), default to "null"'
    echo '    --chatm* model               - settings: set completion model (CHAT_MODEL): gpt-3.5-turbo, gpt-4, ...'
    echo '    --sum model                  - settings: set summary model (CHAT_SUMMARY): gpt-3.5-turbo, gpt-4, ...'
    echo '    --hist tokensize             - settings: set history size token limit (CHAT_HISTSIZE)'
    echo '    --inst* instructionName      - settings: set default instruction to use with new chat (CHAT_INSTRUCTION), see also -o'
    echo '    --model name                 - list details for the named model'
    echo '    --models pattern             - list out all models that match grep pattern'
    echo '    --seed integer               - temporarily set CHAT_SEED to a number'
    echo '    -l<num>|--list<=num>         - list out current chat and "num" most recent chats by ID'
    echo '    -s<range>|--show<=range>     - list chat history with optional range'
    echo '    -I                           - list instructions'
    echo '    -o instructionName           - set temporary override instruction name, will be used instead of default for chat, -o "" to disable'
    echo '    -v                           - enable verbose mode'
    echo '    -d                           - output chat directory path'
    echo '    -S                           - summarize the current chat and rebuild the chat title'
    echo '    -n prompt                    - issue chat prompt, do not load history, but will save to history'
    echo '    -c prompt                    - issue chat prompt for next single argument'
    echo '    -3                           - select model gpt-3.5-turbo'
    echo '    -4p                          - select model gpt-4-1106-preview'
    echo '    -4                           - select model gpt-4'
    echo '    *                            - join all remaining arguments and issue as chat prompt'
    echo ''
    echo 'A chat prompt of - will read standard input'
    echo 'A chat prompt of @ will pop you into the vi editor in insert mode with paste turned on, save to evaluate as chat prompt'
    echo 'A chat prompt of @ followed by text will be read as a filename'
    echo 'Range can be a single number, negative numbers count from the end (-1 = last), a range with <start>..<end>, or a comma separated list of ranges.'
    echo 'Range can only count up, not in reverse.'
    echo ''
    echo 'Environment Variables:'
    echo '     CHAT_BASEDIR                - top of your chat directories, default = $HOME/.chat'
    echo '     CHAT_EDITOR                 - command used to invoke editor, default = vi +startinsert -c "set paste | set sw=4"'
    echo '     CHAT_STDBUF                 - in case you need to replace "stdbuf", but replacement has to handle arguments'
    echo '     COLOR_CHAT                  - set to false if you do not want colorized output, default = true'
    echo '     CURL_WAIT_CONNECT           - curl --connect-timeout, default = 0'
    echo '     CURL_WAIT_COMPLETE          - curl -w, default = 0'
    echo ''
    echo 'Arguments are evaluated in order, so you can issue multiple chats, even across different IDs'
    echo 'Example: chat -n "what is 1+1?" -id geekchat -c "what is a disturginator?" -id bookchat what book should I write next?'
}

handle_prompt() {
    # args: prompt|@|-|/*
    declare content
    case $1 in
        @)
            # create edit buffer
            declare tmpfile="$(mktemp)"
            if [[ -z "$CHAT_EDITOR" ]]; then
                vi +startinsert -c "set paste | set sw=4" "$tmpfile"
            else
                $CHAT_EDITOR "$tmpfile"
            fi
            IFS= read -rd '' content <"$tmpfile"
            do_chat "$content"
            rm -f "$tmpfile"
        ;;
        -)
            # read stdin
            IFS= read -rd '' content <"/dev/stdin"
            do_chat "$content"
        ;;
        @*)
            # read from file
            IFS= read -rd '' content <"${1#@}"
            do_chat "$content"
        ;;
        *) do_chat "$1" ;;
    esac
}

set_property_by_name() {
    # args: propertyName propertyValue
    if exists_in "$1" "${user_properties[@]}"; then
        declare -n propertyRef="$1"
        propertyRef="$2"
        [[ $1 = "CHAT_INSTRUCTION" ]] && set_instruction
        save_settings
    else
        error '%s\n' "Invalid property ${1} in --set" 1>&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -help|--help|-h|'-?') usage; exit 0 ;;
        -to*|--to*)           CHAT_TOKEN="$2"; save_settings; shift ;;
        -max*|--max*)         CHAT_MAXTOKENS="$2"; save_settings; shift ;;
        -chatm*|--chatm*)     CHAT_MODEL="$2"; save_settings; shift ;;
        -sum*|--sum*)         CHAT_SUMMARY="$2"; save_settings; shift ;;
        -hist*|--hist*)       CHAT_HISTSIZE="$2"; save_settings; shift ;;
        -id|--id)             CHAT_ID="$2"; save_settings; shift ;;
        -inst*|--inst*)       set_instruction "$2"; save_settings; shift ;;
        -set|--set)           set_property_by_name "$2" "$3"; save_settings; shift 2 ;;
        -sett*|--sett*)       show_settings ;;
        -model|--model)       get_model "$2"; shift ;;
        -models|--models)     list_models "$2"; shift ;;
        --seed)               CHAT_SEED="$2"; shift ;;
        -l|-list|--list)      list_recent_chats "999" ;;
        -list=*|--list=*)     list_recent_chats "${1#*=}" ;;
        -l*)                  list_recent_chats "${1#-l}" ;;
        -s|-show|--show)      show_chat "1..-1" ;;
        -show=*|--show=*)     show_chat "${1#*=}" ;;
        -s[^a-z]*)            show_chat "${1#-s}" ;;
        -o)                   CHAT_OVERRIDE_INSTRUCTION="$2"; shift ;;
        -I)                   list_instructions ;;
        -d)                   echo "${CHATS}/${CHAT_ID}" ;;
        -S)                   CHAT_SUMMARIZE=true handle_prompt "Please summarize the main topics of this chat so far." ;;
        -n)                   CHAT_NOHIST=true handle_prompt "$2"; shift ;;
        -c)                   handle_prompt "$2"; shift ;;
        -v)                   CHAT_VERBOSE=true ;;
        -3)                   CHAT_MODEL="gpt-3.5-turbo"; save_settings ;;
        -4p)                  CHAT_MODEL="gpt-4-1106-preview"; save_settings ;;
        -4)                   CHAT_MODEL="gpt-4"; save_settings ;;
        @*)                   handle_prompt "$1"; shift ;;
        -)                    handle_prompt "-" ;;
        -*)                   error '%s\n' "unknown option $1" 1>&2; : usage 1>&2; exit 1 ;;
        *)                    do_chat "$*"; exit 0 ;;
    esac
    shift
done

exit 0
