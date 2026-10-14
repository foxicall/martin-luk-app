// These tokens are replaced by Flutter 3.29+ during build/run.
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  // Use the renderer bundled with the build, avoiding a CanvasKit CDN request.
  config: { canvasKitBaseUrl: "canvaskit/" },
  onEntrypointLoaded: async function (engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById("loading")?.remove();
    await appRunner.runApp();
  },
});
