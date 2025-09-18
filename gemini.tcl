package require http
package require tls
package require json

namespace eval gemini {
    variable trigger "!gemini"
    variable api_key $::env(GEMINI_KEY)
    variable api_endpoint "https://generativelanguage.googleapis.com/v1beta/models/"
    variable model "gemini-2.5-flash-lite"
    variable prompt "You are a helpful assistant. Your answers will be relayed over IRC, so they must be in plaintext, and when possible keep to a single line."

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

    set response [gemini::query $text]

    foreach line $response {
        putserv "PRIVMSG $chan :$line"
    }
}

proc gemini::query {query} {
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

    set token [http::geturl $api_endpoint -headers $headers -query $body]

    set status [http::status $token]
    set code [http::ncode $token]

    if {$status ne "ok"} {
        return [list "Error: $status - $code"]
    }

    set json_data [http::data $token]
    set response [json::json2dict $json_data]

    http::cleanup $token

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

    return $lines
}

putlog "gemini.tcl loaded"
