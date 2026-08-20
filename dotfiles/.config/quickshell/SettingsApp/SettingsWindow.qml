import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.shared

FloatingWindow {
    id: root
    visible: false
    title: "MyHyprlandRice Settings"
    implicitWidth: 900
    implicitHeight: 600

    IpcHandler {
        target: "settings"
        function toggle(): void {
            root.visible = !root.visible
        }
    }

    Theme {
        id: theme
    }

    color: theme.background

    property string scriptPath: Quickshell.env("HOME") + "/.config/myhypr/bin/settingsctl"
    property string schemaPath: Quickshell.env("HOME") + "/.config/myhypr/settings-schema.json"

    property var settingsData: []
    property int selectedGroupIndex: 0

    // Load and parse the JSON configuration on startup
    Process {
        command: ["cat", root.schemaPath]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                var rawOutput = this.text.trim();
                if (rawOutput === "" || rawOutput.startsWith("cat: ")) {
                    console.log("ERROR: Could not load the MyHypr settings schema.");
                    return;
                }

                try {
                    root.settingsData = JSON.parse(rawOutput);
                } catch(e) {
                    console.log("Error parsing JSON: ", e);
                }
            }
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ==========================================
        // LEFT SIDEBAR: Group Navigation
        // ==========================================
        Rectangle {
            Layout.preferredWidth: 260
            Layout.fillHeight: true
            color: theme.background

            ListView {
                anchors.fill: parent
                anchors.margins: 15
                spacing: 5
                model: root.settingsData

                delegate: Rectangle {
                    implicitWidth: parent.width
                    implicitHeight: 50
                    radius: 10
                    color: index === root.selectedGroupIndex ? theme.primary : "transparent"

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: 15
                        text: modelData.group
                        font.pixelSize: 16
                        font.family: theme.fontFamily
                        color: index === root.selectedGroupIndex ? theme.on_primary : theme.primary
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.selectedGroupIndex = index
                    }
                }
            }
        }

        // ==========================================
        // RIGHT PANE: Settings Content
        // ==========================================
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: theme.background
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 40

                // Header
                Text {
                    text: root.settingsData[root.selectedGroupIndex] ? root.settingsData[root.selectedGroupIndex].group : "Loading..."
                    font.pixelSize: 28
                    font.bold: true
                    color: theme.on_background
                    font.family: theme.fontFamily
                }

                Text {
                    text: root.settingsData[root.selectedGroupIndex] ? root.settingsData[root.selectedGroupIndex].description : ""
                    font.pixelSize: 14
                    color: theme.on_background
                    Layout.bottomMargin: 20
                    font.family: theme.fontFamily
                }

                // Settings Fields
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 15
                    model: root.settingsData[root.selectedGroupIndex] ? root.settingsData[root.selectedGroupIndex].settings : []

                    // --- ADDED: INTERACTIVE STYLED SCROLLBAR ---
                    ScrollBar.vertical: ScrollBar {
                        policy: ScrollBar.AsNeeded
                        interactive: true // Ensures you can grab and drag it with the mouse

                        // Custom styling to match your dark theme
                        contentItem: Rectangle {
                            implicitWidth: 6
                            implicitHeight: 100
                            radius: 3
                            color: theme.primary
                            // Dims slightly when not interacting with it
                            opacity: parent.pressed ? 1.0 : (parent.active ? 0.8 : 0.4)
                            Behavior on opacity { NumberAnimation { duration: 150 } }
                        }
                    }

                    delegate: Rectangle {
                        // --- ADDED: Margin space for the right-side scrollbar ---
                        width: ListView.view.width - 16
                        implicitHeight: 90
                        color: theme.background
                        radius: 10
                        border.color: theme.primary

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 20

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 4
                                Text {
                                    text: modelData.name
                                    font.pixelSize: 16
                                    font.bold: true
                                    color: theme.primary
                                    font.family: theme.fontFamily
                                }
                                Text {
                                    text: modelData.instructions
                                    font.pixelSize: 12
                                    color: theme.primary
                                    wrapMode: Text.WordWrap
                                    Layout.fillWidth: true
                                    font.family: theme.fontFamily
                                }
                            }

                            // ==========================================
                            // DYNAMIC INPUT AREA (Based on JSON Type)
                            // ==========================================
                            Item {
                                id: fieldItem
                                Layout.preferredWidth: 220
                                Layout.preferredHeight: 40
                                property string exactVal: ""
                                property var dropdownOptions: modelData.type === "choose" ? modelData.options : []

                                // 1. Fetch exact value (--get)
                                Process {
                                    command: [root.scriptPath, "get", modelData.id]
                                    running: true
                                    stdout: StdioCollector {
                                        onStreamFinished: {
                                            fieldItem.exactVal = this.text.trim();
                                        }
                                    }
                                }

                                // 2. Dynamically fetch files/folders list if needed
                                Process {
                                    running: modelData.type === "files" || modelData.type === "folders"
                                    command: {
                                        if (modelData.type === "files") {
                                            return ["find", modelData.folder.replace("~", Quickshell.env("HOME")), "-maxdepth", "1", "-type", "f", "-name", "*.conf", "-printf", "%f\\n"]
                                        } else if (modelData.type === "folders") {
                                            return ["find", modelData.folder.replace("~", Quickshell.env("HOME")), "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\\n"]
                                        }
                                        return ["echo", ""]
                                    }
                                    stdout: StdioCollector {
                                        onStreamFinished: {
                                            var out = this.text.trim();
                                            if (out !== "") {
                                                fieldItem.dropdownOptions = out.split("\n");
                                            }
                                        }
                                    }
                                }

                                // 3. Hidden Save Process (--set)
                                Process {
                                    id: saveProc
                                    running: false
                                }

                                // --- UI COMPONENTS ---

                                // A. TEXTFIELD
                                Rectangle {
                                    anchors.fill: parent
                                    visible: modelData.type === "textfield"
                                    color: theme.background
                                    radius: 10
                                    border.color: theme.primary
                                    border.width: 1

                                    TextInput {
                                        id: valInput
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        verticalAlignment: Text.AlignVCenter
                                        color: theme.on_background
                                        font.pixelSize: 14
                                        text: fieldItem.exactVal
                                        clip: true

                                        Text {
                                            anchors.fill: parent
                                            verticalAlignment: Text.AlignVCenter
                                            text: "Enter value..."
                                            color: theme.primary
                                            visible: valInput.text === ""
                                            font.family: theme.fontFamily
                                        }

                                        onAccepted: {
                                            saveProc.command = [root.scriptPath, "set", modelData.id, valInput.text]
                                            saveProc.running = true
                                            fieldItem.exactVal = valInput.text
                                            valInput.focus = false
                                        }
                                    }
                                }

                                // B. TOGGLE (Switch)
                                Switch {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: modelData.type === "toggle"

                                    checked: {
                                        var tVal = modelData.true_value !== undefined ? modelData.true_value : "true"
                                        return fieldItem.exactVal === tVal
                                    }

                                    // Custom styling for the dark theme
                                    indicator: Rectangle {
                                        implicitWidth: 48
                                        implicitHeight: 26
                                        radius: 13
                                        color: parent.checked ? theme.primary : theme.background
                                        border.color: parent.checked ? theme.primary : theme.primary
                                        border.width: 1

                                        anchors.verticalCenter: parent.verticalCenter

                                        Rectangle {
                                            x: parent.parent.checked ? parent.width - width - 2 : 2
                                            y: 2
                                            width: 22
                                            implicitHeight: 22
                                            radius: 11
                                            color: parent.parent.checked ? theme.background : theme.on_primary
                                            Behavior on x { NumberAnimation { duration: 150 } }
                                        }
                                    }

                                    onClicked: {
                                        var tVal = modelData.true_value !== undefined ? modelData.true_value : "true"
                                        var fVal = modelData.false_value !== undefined ? modelData.false_value : "false"
                                        var newVal = checked ? tVal : fVal

                                        saveProc.command = [root.scriptPath, "set", modelData.id, newVal]
                                        saveProc.running = true
                                        fieldItem.exactVal = newVal
                                    }
                                }

                                // C. DROPDOWN (ComboBox)
                                ComboBox {
                                    id: combo
                                    anchors.fill: parent
                                    visible: modelData.type === "choose" || modelData.type === "files" || modelData.type === "folders"
                                    model: fieldItem.dropdownOptions

                                    // Keep dropdown highlighted choice in sync with exact value
                                    onModelChanged: updateIndex()
                                    Connections {
                                        target: fieldItem
                                        function onExactValChanged() { combo.updateIndex() }
                                    }
                                    function updateIndex() {
                                        var idx = combo.find(fieldItem.exactVal)
                                        if (idx >= 0) combo.currentIndex = idx
                                    }

                                    onActivated: function(index) {
                                        var newVal = combo.textAt(index)
                                        saveProc.command = [root.scriptPath, "set", modelData.id, newVal]
                                        saveProc.running = true
                                        fieldItem.exactVal = newVal
                                    }

                                    // Custom styling for the dropdown button
                                    background: Rectangle {
                                        color: theme.background
                                        border.color: theme.primary
                                        radius: 10
                                    }
                                    contentItem: Text {
                                        text: combo.displayText
                                        font.pixelSize: 14
                                        color: theme.primary
                                        verticalAlignment: Text.AlignVCenter
                                        leftPadding: 10
                                        font.family: theme.fontFamily
                                    }

                                    // Custom styling for the popup menu
                                    popup: Popup {
                                        y: combo.height - 1
                                        implicitWidth: 220
                                        implicitHeight: contentItem.implicitHeight + 16
                                        padding: 8
                                        contentItem: ListView {
                                            clip: true
                                            implicitHeight: contentHeight
                                            model: combo.popup.visible ? combo.delegateModel : null
                                            currentIndex: combo.highlightedIndex
                                            ScrollIndicator.vertical: ScrollIndicator { }
                                        }
                                        background: Rectangle {
                                            color: theme.background
                                            border.color: theme.primary
                                            radius: 10
                                        }
                                    }
                                    delegate: ItemDelegate {
                                        implicitWidth: 204
                                        contentItem: Text {
                                            text: modelData
                                            color: highlighted ? theme.on_primary : theme.primary
                                            font.pixelSize: 14
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        background: Rectangle {
                                            color: highlighted ? theme.primary : "transparent"
                                            radius:4
                                        }
                                        highlighted: combo.highlightedIndex === index
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
