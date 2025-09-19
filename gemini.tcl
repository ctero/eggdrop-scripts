package require http
package require tls
package require json

namespace eval gemini {
    variable trigger "!gemini"
    variable api_key $::env(GEMINI_KEY)
    variable model "gemini-2.5-flash-lite"
    variable prompt "You are a helpful assistant. Your answers will be relayed over IRC, so they must be in plaintext with no markdown, and when possible keep to a single line, otherwise 5 lines maximum. Each line should be no longer than 500 characters."
    set log_stats 1
    variable db_file "data/gemini.db"

    variable api_endpoint "https://generativelanguage.googleapis.com/v1beta/models/"
    append api_endpoint $model ":generateContent"

    bind pub -|- $trigger gemini::command

    setudef flag gemini

    http::register https 443 [list ::tls::socket -autoservername true]
}

proc gemini::command {nick host hand chan text} {
    if {![channel get $chan gemini]} { return }
    variable trigger

    if {[string length [string trim $text]] <= 2} {
        putserv "PRIVMSG $chan :Usage: $trigger <prompt>"
        return 0
    }

    gemini::query $text $nick $chan
}

proc gemini::query {query nick chan} {
    variable api_key
    variable api_endpoint
    variable model
    variable prompt

    set headers [list \
        "Content-Type" "application/json" \
        "x-goog-api-key" $api_key \
    ]

    set body [json::write object \
        system_instruction [json::write object \
            parts [json::write array \
                [json::write object \
                    text [json::write string $prompt] \
                ] \
            ] \
        ] \
        contents [json::write array \
            [json::write object \
                parts [json::write array \
                    [json::write object \
                        text [json::write string $query] \
                    ]
                ]
            ]
        ] \
        tools [json::write array \
            [json::write object \
                google_search [json::write object] \
            ] \
        ] \
    ]

    # Start the asynchronous fetch
    http::geturl $api_endpoint -headers $headers -query $body -command [list gemini::process_data $nick $chan]
}

proc gemini::process_data {nick chan token} {
    upvar #0 $token state
    set status $state(status)
    variable model
    variable api_endpoint
    variable log_stats
    
    if {$status eq "ok"} {
        set json_data $state(body)
        set response [json::json2dict $json_data]

        if {[dict exists $response candidates]} {
            set text_content [dict get [lindex [dict get [lindex [dict get $response candidates] 0] content parts] 0] text]

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
            if {$log_stats && [dict exists $response usageMetadata]} {
                set response_id [dict get $response responseId]

                set usage [dict get $response usageMetadata]

                # Get the required token counts, providing a default of 0 if they don't exist
                set prompt_tokens [dict get $usage promptTokenCount]
                set total_tokens [dict get $usage totalTokenCount]

                set candidates_tokens 0
                if {[dict exists $usage candidatesTokenCount]} {
                    set candidates_tokens [dict get $usage candidatesTokenCount]
                }

                set tool_use_tokens 0
                if {[dict exists $usage toolUsePromptTokenCount]} {
                    set tool_use_tokens [dict get $usage toolUsePromptTokenCount]
                }

                set thoughts_tokens 0
                if {[dict exists $usage thoughtsTokenCount]} {
                    set thoughts_tokens [dict get $usage thoughtsTokenCount]
                }
                
                gemini::log_usage $model $prompt_tokens $candidates_tokens $tool_use_tokens $thoughts_tokens $total_tokens $api_endpoint $chan $nick $response_id

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

proc gemini::log_usage {model ptokens ctokens tutokens thtokens totokens endpoint chan nick response_id} {
    variable db_file
    set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    
    sqlite3 db $db_file
    
    if {[catch {
        db eval {
            INSERT INTO api_requests 
            (timestamp, model, prompt_tokens, candidates_tokens, tool_use_tokens, thoughts_tokens, total_tokens, endpoint, channel, nickname, response_id) 
            VALUES ($timestamp, $model, $ptokens, $ctokens, $tutokens, $thtokens, $totokens, $endpoint, $chan, $nick, $response_id)
        }
    } errmsg]} {
        putlog "ERROR: Failed to log API usage to database. SQLite error: $errmsg"
    }
    
    db close
}

proc gemini::create_db {} {
    variable db_file
    sqlite3 db $db_file

    db eval {
        CREATE TABLE IF NOT EXISTS api_requests (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT DEFAULT CURRENT_TIMESTAMP,
            model TEXT NOT NULL,
            prompt_tokens INTEGER NOT NULL,
            candidates_tokens INTEGER NOT NULL,
            tool_use_tokens INTEGER NOT NULL,
            thoughts_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            endpoint TEXT NOT NULL,
            channel TEXT NOT NULL,
            nickname TEXT NOT NULL,
            response_id TEXT NOT NULL
        )
    }

    db close
}

if {$gemini::log_stats} {
    package require sqlite3

    if {![file exists $gemini::db_file]} {
        gemini::create_db
        putlog "gemini.tcl: Created new database at $gemini::db_file"
    }
}

putlog "gemini.tcl loaded"
