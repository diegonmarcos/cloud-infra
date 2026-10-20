// bun test 1_cloud-configs/src/derive/apk-web-route.test.ts  (#876: wasm APK hosts are Authelia-gated)
import { describe, expect, test } from "bun:test";
import { apkWebRoute } from "./apk-web-route";

const origin = { upstream: "https://diegonmarcos.github.io", path_prefix: "/cloud-web/apps" };
const ctx = (over: any = {}) => ({
  host: "cloud-calc.diegonmarcos.com",
  landing: "https://diegonmarcos.com/landing/cloud-calc/",
  containerUpstream: (c: string) => (c === "cloud-webmail" ? "10.0.0.5:8080" : undefined),
  ...over,
});
const wasm = { kind: "wasm", portal_slug: "cloud-calc", gh_asset: "Cloud-Calc.wasm.zip" };

describe("wasm APK host", () => {
  test("with a declared origin it proxies the bundle, gated by Authelia (no auth: none) with the landing for anonymous", () => {
    const { route, privateUpstream } = apkWebRoute({ name: "cloud-calc", web: wasm }, ctx({ wasmOrigin: origin }));
    expect(route.upstream).toBe(origin.upstream);
    expect(route.web.serve_path).toBe("/cloud-web/apps/cloud-calc/");
    expect(route.landing).toBe("https://diegonmarcos.com/landing/cloud-calc/");
    expect(route.landing_only).toBeUndefined();
    expect(route.auth).toBeUndefined(); // absent auth = the Authelia gate; anonymous gets the redirect
    expect(route.wg_only).toBeUndefined();
    expect(privateUpstream).toBeNull();
  });
  test("a trailing slash on the prefix does not double", () => {
    const { route } = apkWebRoute({ name: "cloud-calc", web: wasm }, ctx({ wasmOrigin: { ...origin, path_prefix: "/cloud-web/apps/" } }));
    expect(route.web.serve_path).toBe("/cloud-web/apps/cloud-calc/");
  });
  test("with no declared origin it renders exactly as before: a landing redirect, never open", () => {
    const { route } = apkWebRoute({ name: "cloud-calc", web: wasm }, ctx());
    expect(route.landing_only).toBe(true);
    expect(route.upstream).toBeUndefined();
    expect(route.auth).not.toBe("none");
  });
  test("a wasm block without a slug, or an origin without a path, is an error not a silent open host", () => {
    expect(() => apkWebRoute({ name: "x", web: { kind: "wasm" } }, ctx({ wasmOrigin: origin }))).toThrow(/portal_slug/);
    expect(() => apkWebRoute({ name: "x", web: wasm }, ctx({ wasmOrigin: { upstream: "u", path_prefix: "nope" } }))).toThrow(/path_prefix/);
  });
});

describe("the other kinds are unchanged", () => {
  test("container: gated proxy plus a private name", () => {
    const { route, privateUpstream } = apkWebRoute({ name: "cloud-mail", web: { kind: "container", target: "cloud-webmail" } }, ctx());
    expect(route.upstream).toBe("10.0.0.5:8080");
    expect(privateUpstream).toBe("10.0.0.5:8080");
    expect(route.auth).toBeUndefined();
  });
  test("container naming a missing container throws", () => {
    expect(() => apkWebRoute({ name: "cloud-mail", web: { kind: "container", target: "nope" } }, ctx())).toThrow(/no HTTP container/);
  });
  test("absent and webapp: landing_only", () => {
    expect(apkWebRoute({ name: "a" }, ctx()).route.landing_only).toBe(true);
    expect(apkWebRoute({ name: "a", web: { kind: "webapp", target: "x" } }, ctx({ wasmOrigin: origin })).route.landing_only).toBe(true);
  });
});
