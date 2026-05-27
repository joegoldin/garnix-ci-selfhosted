export type AgeWasm = {
  encrypt: (
    agePublicKey: string,
    secret: string,
  ) => { ok: true; data: string } | { ok: false; error: string };
};

export async function initAgeWasm(
  ageWasmPromise: Promise<Response>,
): Promise<AgeWasm> {
  // @ts-ignore
  await import("./wasm_exec.js");
  // @ts-expect-error - `Go` is populated globally by `wasm_exec.js` imported above
  const go = new Go();
  const result = await WebAssembly.instantiateStreaming(
    ageWasmPromise,
    go.importObject,
  );
  go.run(result.instance);
  return { encrypt: (globalThis as any).__garnixAgeEncrypt };
}
