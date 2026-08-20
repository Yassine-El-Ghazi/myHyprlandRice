# Start Quickshell in configuration folder
quickshell -p ~/.config/quickshell/shell.qml &

# Toggle Settings App
qs ipc call settings toggle

# Toggle Welcome App
qs ipc call welcome toggle

2. Cross-App Launching

In your Welcome App, you can make the "Dotfiles Settings" button actually trigger the Settings window via IPC rather than launching a whole new process. In your WelcomeWindow.qml button's onClicked:
QML

onClicked: {
    // This tells the background daemon to show the other window
    Quickshell.execDetached(["qs", "ipc", "call", "settings", "open"])
}
