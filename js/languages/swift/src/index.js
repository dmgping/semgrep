import WasmFactory from "../dist/semgrep-parser";

const {
  createParser,
} = require("../../../../_build/default/js/languages/swift/Parser.bc");

export const ParserFactory = async () => {
  const wasm = await WasmFactory();
  return createParser(wasm);
};