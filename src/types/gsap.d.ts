declare module "gsap" {
  interface GsapStatic {
    fromTo(
      targets: unknown,
      fromVars: Record<string, unknown>,
      toVars: Record<string, unknown>,
    ): unknown;
  }

  export const gsap: GsapStatic;
  export default gsap;
}
