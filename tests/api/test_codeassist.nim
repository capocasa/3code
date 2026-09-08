import std/[json, unittest]
import threecode/[codeassist, types]

suite "code assist translation":
  let p = Profile(name: "geminicli.gemini-3.8-flash",
                  model: "gemini-3.8-flash", family: "gemini")

  test "wraps OpenAI body as {model, project, request}":
    let openAi = %*{
      "model": "gemini-3.8-flash",
      "messages": [
        {"role": "system", "content": "you are 3code"},
        {"role": "user", "content": "hi"}
      ],
      "tools": [
        {"type": "function",
         "function": {"name": "bash", "description": "run",
                      "parameters": {"type": "object",
                                     "additionalProperties": false,
                                     "properties": {"command": {"type": "string"}}}}}
      ],
      "max_tokens": 64,
      "reasoning_effort": "medium"
    }
    let j = parseJson(codeAssistBody(p, openAi, "proj-1"))
    check j{"model"}.getStr == "gemini-3.8-flash"
    check j{"project"}.getStr == "proj-1"
    check j{"request"}{"systemInstruction"}{"parts"}[0]{"text"}.getStr == "you are 3code"
    check j{"request"}{"contents"}[0]{"role"}.getStr == "user"
    check j{"request"}{"contents"}[0]{"parts"}[0]{"text"}.getStr == "hi"
    check j{"request"}{"generationConfig"}{"maxOutputTokens"}.getInt == 64
    check j{"request"}{"generationConfig"}{"thinkingConfig"}{"thinkingLevel"}.getStr == "medium"
    check j{"request"}{"tools"}[0]{"functionDeclarations"}[0]{"name"}.getStr == "bash"
    check "additionalProperties" notin j{"request"}{"tools"}[0]{"functionDeclarations"}[0]{"parameters"}

  test "assistant tool_calls become functionCall with bypass signature":
    let openAi = %*{
      "messages": [
        {"role": "user", "content": "edit"},
        {"role": "assistant", "content": "",
         "tool_calls": [
           {"id": "call_1", "type": "function",
            "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}
         ]},
        {"role": "tool", "tool_call_id": "call_1", "content": "ok"}
      ]
    }
    let j = parseJson(codeAssistBody(p, openAi, "p"))
    # first content is user "edit"; second is model functionCall
    let fc = j{"request"}{"contents"}[1]{"parts"}[0]
    check fc{"functionCall"}{"name"}.getStr == "bash"
    check fc{"functionCall"}{"args"}{"command"}.getStr == "ls"
    check fc{"thoughtSignature"}.getStr == "skip_thought_signature_validator"
    let fr = j{"request"}{"contents"}[2]{"parts"}[0]{"functionResponse"}
    check fr{"name"}.getStr == "bash"
    check fr{"response"}{"output"}.getStr == "ok"

  test "SSE event with text becomes OpenAI delta + [DONE]":
    var st: CodeAssistStreamState
    let event = $(%*{
      "response": {
        "candidates": [{
          "content": {"parts": [{"text": "hello"}]},
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 10,
          "candidatesTokenCount": 2,
          "thoughtsTokenCount": 3,
          "totalTokenCount": 15
        }
      }
    })
    let chunks = translateEvent(st, event)
    check chunks.len >= 2
    check chunks[^1] == "[DONE]"
    let delta = parseJson(chunks[0])
    check delta{"choices"}[0]{"delta"}{"content"}.getStr == "hello"
    check delta{"choices"}[0]{"finish_reason"}.getStr == "stop"

  test "SSE thought parts map to reasoning_content":
    var st: CodeAssistStreamState
    let event = $(%*{
      "candidates": [{
        "content": {"parts": [
          {"text": "thinking", "thought": true},
          {"text": "answer"}
        ]}
      }]
    })
    let chunks = translateEvent(st, event)
    let delta = parseJson(chunks[0])
    check delta{"choices"}[0]{"delta"}{"reasoning_content"}.getStr == "thinking"
    check delta{"choices"}[0]{"delta"}{"content"}.getStr == "answer"

  test "SSE functionCall becomes tool_calls delta":
    var st: CodeAssistStreamState
    let event = $(%*{
      "candidates": [{
        "content": {"parts": [
          {"functionCall": {"name": "read", "args": {"path": "a.nim"}}}
        ]},
        "finishReason": "STOP"
      }]
    })
    let chunks = translateEvent(st, event)
    let delta = parseJson(chunks[0])
    let tc = delta{"choices"}[0]{"delta"}{"tool_calls"}[0]
    check tc{"function"}{"name"}.getStr == "read"
    check parseJson(tc{"function"}{"arguments"}.getStr){"path"}.getStr == "a.nim"
    check chunks[^1] == "[DONE]"

  test "non-streaming response translates to choices[0].message":
    let raw = $(%*{
      "response": {
        "candidates": [{
          "content": {"parts": [
            {"text": "done"},
            {"functionCall": {"name": "bash", "args": {"command": "pwd"}}}
          ]},
          "finishReason": "STOP"
        }],
        "usageMetadata": {
          "promptTokenCount": 4,
          "candidatesTokenCount": 1,
          "totalTokenCount": 5
        }
      }
    })
    let j = translateResponse(raw)
    check j{"choices"}[0]{"message"}{"content"}.getStr == "done"
    check j{"choices"}[0]{"message"}{"tool_calls"}[0]{"function"}{"name"}.getStr == "bash"
    check j{"choices"}[0]{"finish_reason"}.getStr == "stop"
    check j{"usage"}{"prompt_tokens"}.getInt == 4
