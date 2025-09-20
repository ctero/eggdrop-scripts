package require http
package require tls
package require json

namespace eval openai {
    variable trigger "grok"
    variable api_key $::env(OPENAI_KEY)
    variable api_endpoint "https://openrouter.ai/api/v1/chat/completions"
    variable model "x-ai/grok-4-fast:free"
    variable prompt "You are a helpful assistant. Your answers will be relayed over IRC, so they must be in plaintext with no markdown, and when possible keep to a single line, otherwise 5 lines maximum. Each line should be no longer than 500 characters."
    set log_stats 1
    variable db_file "data/openai.db"
    
    bind pub -|- $trigger openai::command

    setudef flag openai

    http::register https 443 [list ::tls::socket -autoservername true]
}

proc openai::command {nick host hand chan text} {
    if {![channel get $chan openai]} { return }
    variable trigger

    if {[string length [string trim $text]] <= 2} {
        putserv "PRIVMSG $chan :Usage: $trigger <prompt>"
        return 0
    }

    openai::query $text $nick $chan
}

proc openai::query {query nick chan} {
    variable api_key
    variable api_endpoint
    variable model
    variable prompt

    set headers [list \
        "Content-Type" "application/json" \
        "Authorization" "Bearer $api_key" \
    ]

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
            ]
        ]
    ]

    # Start the asynchronous fetch
    http::geturl $api_endpoint -headers $headers -query $body -command [list openai::process_data $nick $chan]
}

proc openai::process_data {nick chan token} {
    upvar #0 $token state
    set status $state(status)
    variable api_endpoint
    variable log_stats
    
    if {$status eq "ok"} {
        set json_data $state(body)
        set response [json::json2dict $json_data]

        if {[dict exists $response choices]} {
            set text_content [dict get [lindex [dict get $response choices] 0] message content]

            set lines {}
            set line_count 0
            foreach line [split $text_content "\n"] {
                if {[string trim $line] ne ""} {
                    incr line_count
                    if {$line_count > 4} {
                        lappend lines "Output truncated to 5 lines to avoid spam."
                        break
                    }
                    lappend lines $line
                }
            }

            foreach line $lines {
                putserv "PRIVMSG $chan :$line"
            }

            # log usage
            if {$log_stats && [dict exists $response usage]} {
                set response_id [dict get $response id]
                set model_name [dict get $response model]
                set provider [dict get $response provider]

                set usage [dict get $response usage]

                # Get the required token counts, providing a default of 0 if they don't exist
                set prompt_tokens [dict get $usage prompt_tokens]
                set completion_tokens [dict get $usage completion_tokens]
                set total_tokens [dict get $usage total_tokens]

                openai::log_usage $provider $model $prompt_tokens $completion_tokens $total_tokens $api_endpoint $chan $nick $response_id

            } else {
                putlog "No usage metadata found"
            }
        } else {
            putserv "PRIVMSG $chan :Error: No candidates found in response."
        }
    } else {
        putserv "PRIVMSG $chan :Error: $status"
    }

    http::cleanup $token
}

proc openai::log_usage {provider model ptokens ctokens totokens endpoint chan nick response_id} {
    variable db_file
    set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    
    sqlite3 db $db_file
    
    if {[catch {
        db eval {
            INSERT INTO api_requests 
            (timestamp, provider, model, prompt_tokens, completion_tokens, total_tokens, endpoint, channel, nickname, response_id) 
            VALUES ($timestamp, $provider, $model, $ptokens, $ctokens, $totokens, $endpoint, $chan, $nick, $response_id)
        }
    } errmsg]} {
        putlog "ERROR: Failed to log API usage to database. SQLite error: $errmsg"
    }
    
    db close
}

proc openai::create_db {} {
    variable db_file
    sqlite3 db $db_file

    db eval {
        CREATE TABLE IF NOT EXISTS api_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
            provider TEXT,
            model TEXT NOT NULL,
            prompt_tokens INTEGER NOT NULL,
            completion_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            endpoint TEXT NOT NULL,
            channel TEXT NOT NULL,
            nickname TEXT NOT NULL,
            response_id TEXT NOT NULL
        )
    }

    db close
}

if {$openai::log_stats} {
    package require sqlite3

    if {![file exists $openai::db_file]} {
        openai::create_db
        putlog "openai.tcl: Created new database at $openai::db_file"
    }
}

putlog "openai.tcl loaded"
