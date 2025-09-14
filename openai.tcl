#
# openai.tcl - Eggdrop script to query an OpenAI-compatible API
#
# This script requires Tcl 9, which is used by Eggdrop 1.10.1+.
# It uses the Tcl 'http' and 'json' packages for API interaction.
#
# Configuration:
#
#   1. Set your API key, endpoint and model below.
#   2. Add 'source scripts/openai.tcl' to your Eggdrop config file.
#   3. You may need to install the 'http' and 'json' Tcl packages if they
#      aren't already present.
#      - Tcl packages can often be installed via your system's package manager
#        or by using 'tclkit' and 'teacup'.

namespace eval ::openai {}

package require http
package require json
package require tls

http::register https 443 [list ::tls::socket -autoservername true]

set ::openai::trigger "!openai"
set ::openai::api_key "API_KEY_HERE"
set ::openai::api_endpoint "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
set ::openai::model "gemini-2.5-flash-lite"
set ::openai::prompt "You are a helpful assistant."

#
# Function to query the API
#
proc ::openai::query {query} {
    set headers {
        "Content-Type" "application/json"
    }
    lappend headers "Authorization" "Bearer $::openai::api_key"

    set body [json::write object \
        model    [json::write string $::openai::model] \
        messages [json::write array \
            [json::write object \
                role    [json::write string "system"] \
                content [json::write string $::openai::prompt] \
            ] \
            [json::write object \
                role    [json::write string "user"] \
                content [json::write string $query] \
            ] \
        ] \
    ]

    set token [http::geturl $::openai::api_endpoint -headers $headers -query $body]

    set status [http::status $token]
    set code [http::ncode $token]

    if {$status ne "ok"} {
        return "Error: $status - $code"
    }

    set json_data [http::data $token]
    set response [json::json2dict $json_data]

    http::cleanup $token

    if {[dict exists $response choices]} {
        set message [dict get [lindex [dict get $response choices] 0] message content]
        set lines {}
        set line_count 0
        foreach line [split $message "\n"] {
            if {[string trim $line] ne ""} {
                incr line_count
                if {$line_count > 4} {
                    lappend lines "Output truncated to 5 lines to avoid spam."
                    break
                }
                lappend lines $line
            }
        }
        #return [string trim $message]
        return $lines
    } else {
        return "Error: Unable to parse API response."
    }
}

#
# Bind the command to the channel
#
bind pub - $::openai::trigger ::openai::command

proc ::openai::command {nick host handle channel text} {
    if {[string length $text] < 2} {
        putserv "PRIVMSG $channel :Usage: $::openai::trigger <prompt>"
        return 0
    }
    
    set prompt [string range $text 1 end]
    #putserv "PRIVMSG $channel :Querying OpenAI..."
    
    # Run the query in the background to avoid blocking the bot
    set response [::openai::query $prompt]
    
    #putserv "PRIVMSG $channel :$nick: $response"
    foreach line $response {
        putserv "PRIVMSG $channel :$line"
    }
}
