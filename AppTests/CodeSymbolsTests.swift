import Testing
@testable import Sevinda

struct CodeSymbolsTests {
    @Test func swiftDeclarations() {
        let source = """
        import SwiftUI

        @MainActor
        public final class Store {
            private static func load(id: Int) -> Int { id }
            init(name: String) {}
            func save() async throws {}
        }
        extension Store: Sendable {}
        let x = 1
        """
        let symbols = CodeSymbols.symbols(in: source, language: "swift")
        #expect(symbols.map(\.name) == ["Store", "load", "init", "save", "Store"])
        #expect(symbols.map(\.line) == [4, 5, 6, 7, 9])
        #expect(symbols[1].kind == .function && symbols[0].kind == .type)
    }

    @Test func typescriptDeclarations() {
        let source = """
        export default function AppLayout() {
        const useThing = async (a: number) => {
        export const Card: React.FC<Props> = ({ title }) => {
        interface Props {
        export type Mode = 'a' | 'b'
        class Repo {
          async fetch(id: string): Promise<void> {
          if (ready) {
        }
        """
        let names = CodeSymbols.symbols(in: source, language: "tsx").map(\.name)
        #expect(names == ["AppLayout", "useThing", "Card", "Props", "Mode", "Repo", "fetch"])
    }

    @Test func pythonGoRustAndUnknown() {
        #expect(CodeSymbols.symbols(in: "class A:\n    async def run(self):\n", language: "python").map(\.name) == ["A", "run"])
        #expect(CodeSymbols.symbols(in: "type Server struct {}\nfunc (s *Server) Start() {}\n", language: "go").map(\.name) == ["Server", "Start"])
        #expect(CodeSymbols.symbols(in: "pub struct A;\nimpl A {\n    pub async fn go() {}\n}\n", language: "rust").map(\.name) == ["A", "A", "go"])
        #expect(CodeSymbols.symbols(in: "anything", language: "json").isEmpty)
    }
}
