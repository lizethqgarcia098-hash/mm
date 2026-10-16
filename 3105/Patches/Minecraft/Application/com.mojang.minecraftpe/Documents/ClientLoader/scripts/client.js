ClientMenu.registerFeature("Demo script preference", false, function (enabled) {
    console.log("Demo script preference:", enabled);
});

ClientMenu.registerAction("Loader status", function () {
    ClientMenu.notify(
        "The floating client menu is running. Gameplay actions still need Minecraft-specific hooks."
    );
});
