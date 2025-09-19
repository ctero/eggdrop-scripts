package require http
package require tls
package require json
package require sqlite3

namespace eval gemini {
    variable trigger "!gemini"
    variable api_key $::env(GEMINI_KEY)
    variable api_endpoint "https://generativelanguage.googleapis.com/v1beta/models/"
    variable model "gemini-2.5-flash-lite"
    variable prompt "You are a helpful assistant. Your answers will be relayed over IRC, so they must be in plaintext with no markdown, and when possible keep to a single line, otherwise 5 lines maximum. Each line should be no longer than 500 characters."
    variable db_file "data/$::botnick.db"

    append api_endpoint $model ":generateContent"

    bind pub -|- $trigger gemini::command

    setudef flag gemini
}

http::register https 443 [list ::tls::socket -autoservername true]

proc gemini::command {nick host hand chan text} {
    if {![channel get $chan gemini]} { return }
    variable trigger

    if {[string length [string trim $text]] <= 2} {
        putserv "PRIVMSG $chan :Usage: $trigger <prompt>"
        return 0
    }

    gemini::query $text $chan
}

proc gemini::query {query chan} {
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
    http::geturl $api_endpoint -headers $headers -query $body -command [list gemini::process_data $chan]
}

proc gemini::process_data {chan token} {
    upvar #0 $token state
    set status $state(status)
    variable model
    variable api_endpoint
    
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
            if {[dict exists $response usageMetadata]} {
                putlog "Found usage metadata, processing..."
                set usage [dict get $response usageMetadata]

                # Get the required token counts, providing a default of 0 if they don't exist
                set prompt_tokens [dict get $usage promptTokenCount]
                set total_tokens [dict get $usage totalTokenCount]

                # Safely calculate completion tokens
                set completion_tokens 0
                if {[dict exists $usage candidatesTokenCount]} {
                    incr completion_tokens [dict get $usage candidatesTokenCount]
                }
                if {[dict exists $usage toolUsePromptTokenCount]} {
                    incr completion_tokens [dict get $usage toolUsePromptTokenCount]
                }
                if {[dict exists $usage thoughtsTokenCount]} {
                    incr completion_tokens [dict get $usage thoughtsTokenCount]
                }

                set cost 0.00
                
                putlog "Data processed, attempting to log usage..."
                gemini::log_usage $model $prompt_tokens $completion_tokens $total_tokens $cost $api_endpoint

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

proc gemini::log_usage {model ptokens ctokens ttokens cost endpoint} {
    variable db_file
    set timestamp [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]
    
    sqlite3 db $db_file
    
    # This is the clearest and most secure syntax.
    # The 'catch' block will trap any errors from the 'db eval' command.
    if {[catch {
        db eval {
            INSERT INTO api_requests 
            (timestamp, model, prompt_tokens, completion_tokens, total_tokens, cost, api_endpoint) 
            VALUES ($timestamp, $model, $ptokens, $ctokens, $ttokens, $cost, $endpoint)
        }
    } errmsg]} {
        putlog "ERROR: Failed to log API usage to database. SQLite error: $errmsg"
    } else {
        putlog "Logged API usage: model=$model, prompt_tokens=$ptokens, completion_tokens=$ctokens, total_tokens=$ttokens, cost=$cost, endpoint=$endpoint"
    }
    
    db close
}

putlog "gemini.tcl loaded"
