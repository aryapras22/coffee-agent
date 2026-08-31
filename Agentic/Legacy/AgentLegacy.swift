//
//  Agent.swift
//  Agentic
//
//  Created by Arya on 24/08/26.
//

import FoundationModels

class Agent {
    let model = SystemLanguageModel.default
    
    func checkAvailability(){
        switch model.availability {
        case .available:
            print("System is available")
        case .unavailable:
            print("System is unavailable")
        }
    }
    
    func request(req: String) async throws{
        let session = LanguageModelSession(tools: [generateExampleDataTool()], instructions: "You are a concise, friendly assistant.")
        do {
            let _ = try await session.respond(to: req)
        } catch let error as LanguageModelSession.ToolCallError {
            print("Tool", error.tool.name, "failed", error.underlyingError)
        } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
            
        } catch {
            print("Other Error: ", error)
        }
        
        for entry in session.transcript {
            switch entry {
            case .prompt(let p):
                print("Prompt: \(p)")
            case .toolCalls(let t):
                print("Tool: \(t)")
            case .toolOutput(let to):
                print("Tool Output: \(to)")
            case .response(let r):
                print("Response: \(r)")
            default :
                break
            }
        }
    }
}

struct generateExampleDataTool: Tool {
    let name = "createRandomWeather"
    let description = "Create a random weather for you"
    
    @Generable
    struct Arguments {
        @Guide(description: "random name of day")
        var day: String
        
        @Guide(description: "random weather tips")
        var tips: [String]
    }
    
    func call(arguments: Arguments) async throws -> WeatherResult{
        return WeatherResult(day: arguments.day, tips: arguments.tips)
    }
}

@Generable
struct WeatherResult {
    var day: String
    var tips: [String]
}
