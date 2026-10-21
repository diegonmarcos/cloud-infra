/**
 * apk-web-route.ts -- the vhost route of one APK host, from the APK's build.json `web` block (#876).
 *
 *   web.kind "container"  Authelia (bearer or session) gates a reverse proxy to that container.
 *   web.kind "wasm"       Authelia gates the app's Kotlin/Wasm bundle, served from the declared
 *                         `url_scheme.wasm_origin` ({ upstream, path_prefix }): the route proxies to
 *                         `upstream` and `web.serve_path` is the path the bundle lives at
 *                         (<path_prefix>/<web.portal_slug>/). Until wasm_origin is declared (the
 *                         owner's deploy decision) a wasm app renders exactly as before: landing_only.
 *   absent / webapp       landing_only (every request 302s to the landing page).
 *
 * No route built here ever carries `auth: "none"`: absent `auth` is the Authelia gate (an anonymous
 * request is redirected to the landing page / Authelia login by the renderer), and the tests pin that.
 */
export interface WasmOrigin { upstream: string; path_prefix: string }

export interface ApkWebCtx {
  host: string;
  landing: string;
  containerUpstream: (container: string) => string | undefined;
  wasmOrigin?: WasmOrigin | null;
}

export interface ApkWebRoute {
  route: Record<string, any>;
  /** Container upstream that also earns the APK a private cloud-<name>.app name; null otherwise. */
  privateUpstream: string | null;
}

export function apkWebRoute(app: { name: string; web?: any }, ctx: ApkWebCtx): ApkWebRoute {
  const name = String(app.name);
  let web: any = app.web ?? null;
  let upstream: string | undefined;
  let privateUpstream: string | null = null;
  let comment = `APK ${name}: no web target, landing redirect`;

  if (web?.kind === "container") {
    upstream = ctx.containerUpstream(web.target);
    if (!upstream) throw new Error(`APK ${name} declares web container '${web.target}' but no HTTP container of that name exists`);
    privateUpstream = upstream;
    comment = `APK ${name}: web target container ${web.target}`;
  } else if (web?.kind === "wasm" && ctx.wasmOrigin) {
    const slug = String(web.portal_slug ?? "");
    if (!slug) throw new Error(`APK ${name} declares web wasm but no portal_slug`);
    const { upstream: up, path_prefix: prefix } = ctx.wasmOrigin;
    if (!up || !prefix?.startsWith("/")) throw new Error(`url_scheme.wasm_origin needs upstream and a path_prefix starting with /`);
    upstream = up;
    web = { ...web, serve_path: `${prefix.replace(/\/$/, "")}/${slug}/` };
    comment = `APK ${name}: web target wasm bundle ${slug} (Authelia-gated)`;
  }

  return {
    route: {
      domain: ctx.host,
      ...(upstream ? { upstream } : { landing_only: true }),
      landing: ctx.landing,
      apk: name,
      ...(web ? { web } : {}),
      comment,
    },
    privateUpstream,
  };
}
