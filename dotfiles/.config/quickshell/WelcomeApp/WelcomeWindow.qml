import Quickshell
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell.Io
import qs.shared

FloatingWindow {
    id: root
    visible: false
    title: "MyHyprlandRice Welcome"
    implicitWidth: 850
    implicitHeight: 550

    IpcHandler {
        target: "welcome"
        function toggle(): void {
            root.visible = !root.visible
        }
    }

    Theme {
        id: theme
    }

    Process {
        id: appLauncher
        running: false
    }

    // Define a custom reusable styled MenuItem
    component MyHyprMenuItem: MenuItem {
        id: control

        contentItem: Text {
            text: control.text
            font.family: theme.fontFamily
            font.pixelSize: 14
            // Invert colors on hover
            color: control.highlighted ? theme.background : theme.primary
            verticalAlignment: Text.AlignVCenter
        }

        background: Rectangle {
            implicitWidth: 220
            implicitHeight: 36
            // Apply theme color on hover
            color: control.highlighted ? theme.primary : "transparent"
            radius: 4
        }
    }

    component MyHyprMenuSeparator: MenuSeparator {
        contentItem: Rectangle {
            implicitWidth: 200
            implicitHeight: 1
            color: theme.primary
            opacity: 0.3 // Dim the line so it doesn't distract from text
        }
    }

    color: theme.background

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // ==========================================
        // TRADITIONAL MENU BAR
        // ==========================================
        MenuBar {
            Layout.fillWidth: true
            Layout.margins: 10
            background: Rectangle {
                color: theme.primary
                border.color: theme.primary
                radius: 8
            }

            // --- SETTINGS MENU ---
            Menu {
                title: qsTr("Settings")
                font.family: theme.fontFamily
                font.pixelSize: 14
                padding:8

                enter: Transition { NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutQuad } }
                exit: Transition { NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 150; easing.type: Easing.InQuad } }

                MyHyprMenuItem {
                    text: qsTr("Keyboard");
                    onClicked: { appLauncher.command = ["gnome-text-editor", Quickshell.env("HOME") + "/.config/hypr/conf/keyboard.lua"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Monitors");
                    onClicked: { appLauncher.command = ["nwg-displays"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Network");
                    onClicked: { appLauncher.command = [Quickshell.env("HOME") + "/.config/myhypr/settings/networkmanager.sh"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Bluetooth");
                    onClicked: { appLauncher.command = ["blueman-manager"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Wallpaper");
                    onClicked: { appLauncher.command = ["waypaper", "--backend", "awww"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Theme");
                    onClicked: { appLauncher.command = ["nwg-look"]; appLauncher.running = true }
                }
                MyHyprMenuSeparator {}
                MyHyprMenuItem {
                    text: qsTr("Dotfiles Settings");
                    onClicked: {
                        appLauncher.command = ["qs", "ipc", "call", "settings", "toggle"]
                        appLauncher.running = true
                    }
                }
                MyHyprMenuItem {
                    text: qsTr("Hyprland Configuration")
                    onClicked: {
                        appLauncher.command = ["gnome-text-editor", Quickshell.env("HOME") + "/.config/hypr/hyprland.lua"]
                        appLauncher.running = true
                    }
                }
                background: Rectangle {
                    implicitWidth: 220
                    color: theme.background
                    border.color: theme.primary
                    border.width: 1
                    radius: 8
                }
            }

            // --- System MENU ---
            Menu {
                title: qsTr("System")
                font.family: theme.fontFamily
                font.pixelSize: 14
                padding:8

                enter: Transition { NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutQuad } }
                exit: Transition { NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 150; easing.type: Easing.InQuad } }

                MyHyprMenuItem {
                    text: qsTr("Desktop Doctor");
                    onClicked: { appLauncher.command = ["kitty", "--class", "dotfiles-floating", "-e", Quickshell.env("HOME") + "/.config/myhypr/bin/myhyprctl", "doctor"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Network Manager Applet");
                    onClicked: { appLauncher.command = [Quickshell.env("HOME") + "/.config/myhypr/scripts/nm-applet.sh", "toggle"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("Change Shell");
                    onClicked: { appLauncher.command = ["kitty", "--class", "dotfiles-floating", "-e", Quickshell.env("HOME") + "/.config/myhypr/scripts/shell.sh"]; appLauncher.running = true }
                }
                MyHyprMenuItem {
                    text: qsTr("System Info")
                    onClicked: { appLauncher.command = ["kitty", "--class", "dotfiles-floating", "-e", Quickshell.env("HOME") + "/.config/hypr/scripts/systeminfo.sh"]; appLauncher.running = true }
                }
                MyHyprMenuSeparator {}
                MyHyprMenuItem {
                    text: qsTr("Exit Hyprland")
                    onClicked: { appLauncher.command = ["qs", "ipc", "call", "power", "toggle"]; appLauncher.running = true }
                }

                background: Rectangle {
                    implicitWidth: 220
                    color: theme.background
                    border.color: theme.primary
                    border.width: 1
                    radius: 8
                }
            }

            // --- HELP MENU ---
            Menu {
                title: qsTr("Help")
                font.family: theme.fontFamily
                font.pixelSize: 14
                padding:8

                enter: Transition { NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 200; easing.type: Easing.OutQuad } }
                exit: Transition { NumberAnimation { property: "opacity"; from: 1.0; to: 0.0; duration: 150; easing.type: Easing.InQuad } }

                MyHyprMenuItem { text: qsTr("MyHyprlandRice GitHub"); onClicked: { appLauncher.command = ["xdg-open", "https://github.com/Yassine-El-Ghazi/myHyprlandRice"]; appLauncher.running = true } }
                MyHyprMenuItem { text: qsTr("Local Documentation"); onClicked: { appLauncher.command = [Quickshell.env("HOME") + "/.config/myhypr/bin/myhyprctl", "docs"]; appLauncher.running = true } }
                MyHyprMenuSeparator {}
                MyHyprMenuItem { text: qsTr("Hyprland Homepage"); onClicked: { appLauncher.command = ["xdg-open", "https://hypr.land/"]; appLauncher.running = true } }
                MyHyprMenuItem { text: qsTr("Hyprland Wiki"); onClicked: { appLauncher.command = ["xdg-open", "https://wiki.hypr.land/"]; appLauncher.running = true } }
                MyHyprMenuItem { text: qsTr("Update Dotfiles"); onClicked: { appLauncher.command = ["kitty", "--class", "dotfiles-floating", "-e", Quickshell.env("HOME") + "/.config/myhypr/bin/myhyprctl", "update"]; appLauncher.running = true } }

                background: Rectangle {
                    implicitWidth: 180
                    color: theme.background
                    border.color: theme.primary
                    radius: 8
                }
            }

            // --- UNIVERSAL STYLING FOR ALL MENUS ---
            delegate: MenuBarItem {
                id: menuBarItem
                contentItem: Text {
                    text: menuBarItem.text
                    font.pixelSize: 14
                    font.family: theme.fontFamily
                    color: theme.on_primary
                    horizontalAlignment: Text.AlignLeft
                    verticalAlignment: Text.AlignVCenter
                }
                background: Rectangle {
                    color: "transparent"
                    radius: theme.on_primary
                }
            }
        }

        // ==========================================
        // MAIN CONTENT AREA
        // ==========================================
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: "transparent"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 10
                spacing: 10

                // --- MAIN HERO SECTION ---
                ColumnLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 10
                    Layout.topMargin: 20

                    Image {
                        Layout.alignment: Qt.AlignHCenter
                        source: "../shared/MyHyprLogo.svg"
                        sourceSize.width: 100
                        sourceSize.height: 100
                        width: 100
                        height: 100
                        fillMode: Image.PreserveAspectFit
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Welcome to MyHyprlandRice"
                        font.family: theme.fontFamily
                        font.pixelSize: 28
                        font.bold: true
                        color: theme.on_background
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        font.family: theme.fontFamily
                        text: "Dotfiles for Hyprland"
                        font.pixelSize: 20
                        font.bold: true
                        color: theme.on_background
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Standalone Edition"
                        font.family: theme.fontFamily
                        font.pixelSize: 16
                        color: theme.on_background
                        Layout.bottomMargin: 10
                    }

                    // Action Buttons
                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter
                        spacing: 15

                        Button {
                            text: "Dotfiles Settings"
                            onClicked: {
                                appLauncher.command = ["qs", "ipc", "call", "settings", "toggle"]
                                appLauncher.running = true
                            }
                            background: Rectangle {
                                color: "transparent"
                                radius: 10
                                border.color: theme.primary
                            }
                            contentItem: Text {
                                text: parent.text
                                font.family: theme.fontFamily
                                color: theme.primary
                                padding: 8
                            }
                        }

                        Button {
                            text: "Hyprland Config"

                            onClicked: {
                                appLauncher.command = ["gnome-text-editor", Quickshell.env("HOME") + "/.config/hypr/hyprland.lua"]
                                appLauncher.running = true
                            }
                            background: Rectangle {
                                color: "transparent"
                                radius: 10
                                border.color: theme.primary
                            }
                            contentItem: Text {
                                text: parent.text
                                font.family: theme.fontFamily
                                color: theme.primary
                                padding: 8
                            }
                        }
                    }
                }

                Item { Layout.fillHeight: true } // Spacer

                // --- KEYBINDINGS GRID ---
                ColumnLayout {
                    Layout.alignment: Qt.AlignHCenter
                    spacing: 8

                    Repeater {
                        model: ListModel {
                            ListElement { keys: "Super + Enter"; desc: "to open the terminal" }
                            ListElement { keys: "Super + B"; desc: "to open the browser" }
                            ListElement { keys: "Super + Space"; desc: "to open the application launcher" }
                            ListElement { keys: "Super + Q"; desc: "to close the active window" }
                        }

                        delegate: RowLayout {
                            spacing: 15

                            Text {
                                text: model.keys
                                color: theme.primary
                                font.family: theme.fontFamily
                                font.bold: true
                                font.pixelSize: 13
                                Layout.preferredWidth: 120
                                horizontalAlignment: Text.AlignRight
                            }

                            Text {
                                text: model.desc
                                color: theme.on_background
                                font.family: theme.fontFamily
                                font.pixelSize: 13
                                Layout.preferredWidth: 240
                            }
                        }
                    }

                    Button {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: 15
                        text: "All keybindings"

                        onClicked: {
                            appLauncher.command = [Quickshell.env("HOME") + "/.config/hypr/scripts/keybindings.sh"]
                            appLauncher.running = true
                        }

                        background: Rectangle {
                            color: "transparent"
                            border.color: theme.primary
                            radius: 10
                        }
                        contentItem: Text {
                            text: parent.text
                            font.family: theme.fontFamily
                            color: theme.primary
                            padding: 8
                        }
                    }
                }

                Item { Layout.fillHeight: true }

                // ==========================================
                // BOTTOM BAR: SHOW ON STARTUP
                // ==========================================
                RowLayout {
                    Layout.fillWidth: true
                    Layout.margins: 10

                    Item { Layout.fillWidth: true }

                    Text {
                        text: qsTr("Show on Startup")
                        color: theme.primary
                        font.family: theme.fontFamily
                        font.pixelSize: 14
                        Layout.alignment: Qt.AlignVCenter
                    }

                    Switch {
                        id: autostartSwitch
                        Layout.alignment: Qt.AlignVCenter

                        implicitWidth: 48
                        implicitHeight: 26

                        property bool ready: false

                        Process {
                            command: [Quickshell.env("HOME") + "/.config/myhypr/bin/settingsctl", "get", "welcome_on_startup"]
                            running: root.visible
                            stdout: StdioCollector {
                                onStreamFinished: {
                                    let output = this.text.trim()
                                    autostartSwitch.checked = (output === "True")
                                    autostartSwitch.ready = true
                                }
                            }
                        }

                        indicator: Rectangle {
                            implicitWidth: 48
                            implicitHeight: 26
                            radius: 13

                            color: autostartSwitch.checked ? theme.primary : theme.background
                            border.color: theme.primary
                            border.width: 1

                            Rectangle {
                                x: autostartSwitch.checked ? parent.width - width - 2 : 2
                                y: 2
                                width: 22
                                height: 22
                                radius: 11
                                color: autostartSwitch.checked ? theme.background : theme.on_primary
                                Behavior on x { NumberAnimation { duration: 150 } }
                            }
                        }

                        onClicked: {
                            if (!ready) return;

                            appLauncher.running = false
                            appLauncher.command = [Quickshell.env("HOME") + "/.config/myhypr/bin/settingsctl", "set", "welcome_on_startup", checked ? "True" : "False"]
                            appLauncher.running = true
                        }
                    }
                }
            }
        }
    }
}
