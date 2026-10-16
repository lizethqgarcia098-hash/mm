ClientMenu.registerFeature("Synthetic ESP test boxes", false, function (enabled) {
    ClientMenu.setSyntheticESPEnabled(enabled);
});

ClientMenu.registerFeature("Live mob ESP", false, function (enabled) {
    ClientMenu.setLiveESPEnabled(enabled);
});

ClientMenu.registerAction("Export chunk data diagnostic", function () {
    var filePath = ClientMenu.exportDiagnostics("ChunkCaptureDiagnostic.json");
    if (filePath) {
        ClientMenu.notify(
            "Diagnostic report saved:\n" + filePath
        );
    } else {
        ClientMenu.notify("Diagnostic export failed. Check ClientLoader.log for details.");
    }
});
