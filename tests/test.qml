import QtQuick 2.0
import NimExtension 1.0


Rectangle {
    id: page
    width: 480; height: 320
    color: "lightgray"

    Student {
    	id: model
	name: "John"
	age: 30
    }



    Text {
        id: helloText
        text: "Hello " + model.name
        y: 30
        anchors.horizontalCenter: page.horizontalCenter
        font.pointSize: 24; font.bold: true
    }

    MouseArea {
        anchors.fill: parent
        onClicked: {
	  page.color = "black"
	  helloText.color = "darkgreen"
	  helloText.text = "Welcome Geeks!!!"
//	  nim.value = "Welcome to Nim"
        }
    }

}
