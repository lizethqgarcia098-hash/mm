ClientMenu.registerAction("Check snapshot contract bridge", function () {
    if (typeof ClientMenu.snapshotContractStatus !== "function") {
        ClientMenu.notify(
            "Snapshot bridge is missing. Rebuild and install the ClientLoader dylib."
        );
        return;
    }

    var status = ClientMenu.snapshotContractStatus();
    var message = "Snapshot schema v" + status.schemaVersion +
        "\nValidator linked: " + status.validatorLinked +
        "\nProvider: " + status.providerStatus +
        "\nLive data available: " + status.liveDataAvailable +
        "\n" + status.limitation;
    ClientMenu.notify(message);
});

ClientMenu.notify(
    "Snapshot probe loaded. Open the C menu and choose " +
    "\"Check snapshot contract bridge\" to test the native bridge."
);
