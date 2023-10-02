MODULE_NAME='mAudacSMQComm'	(
                                dev vdvControl,
                                dev vdvCommObjects[],
                                dev dvPort
                            )

(***********************************************************)
#include 'NAVFoundation.ModuleBase.axi'
#include 'NAVFoundation.SocketUtils.axi'

/*
 _   _                       _          ___     __
| \ | | ___  _ __ __ _  __ _| |_ ___   / \ \   / /
|  \| |/ _ \| '__/ _` |/ _` | __/ _ \ / _ \ \ / /
| |\  | (_) | | | (_| | (_| | ||  __// ___ \ V /
|_| \_|\___/|_|  \__, |\__,_|\__\___/_/   \_\_/
                 |___/

MIT License

Copyright (c) 2023 Norgate AV Services Limited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

(***********************************************************)
(*          DEVICE NUMBER DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_DEVICE

(***********************************************************)
(*               CONSTANT DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_CONSTANT
constant long TL_IP_CHECK = 1
constant long TL_QUEUE_FAILED_RESPONSE	= 2
constant long TL_HEARTBEAT	= 3
constant long TL_REGISTER	= 4


constant integer MAX_QUEUE_COMMANDS = 50
constant integer MAX_QUEUE_STATUS = 100
constant integer MAX_OBJECTS	= 100
constant integer MAX_OBJECT_TAGS	= 5

constant integer TELNET_WILL	= $FB
constant integer TELNET_DO	= $FD
constant integer TELNET_DONT	= $FE
constant integer TELNET_WONT	= $FC

constant integer COMM_MODE_ONE_WAY	= 1
constant integer COMM_MODE_TWO_WAY	= 2

(***********************************************************)
(*              DATA TYPE DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_TYPE
struct _Object {
    integer iInitialized
    integer iRegistered
}

struct _Queue {
    integer iBusy
    integer iHasItems
    integer iCommandHead
    integer iCommandTail
    integer iStatusHead
    integer iStatusTail
    integer iStrikeCount
    integer iResendLast
    char cLastMess[NAV_MAX_BUFFER]
}

(***********************************************************)
(*               VARIABLE DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_VARIABLE
volatile long ltHeartbeat[] = { 30000 }
volatile long ltIPCheck[] = { 3000 }
volatile long ltQueueFailedResponse[]	= { 2500 }
volatile long ltRegister[]	= { 500 }

volatile long ltFeedback[] = { 200 }

volatile _Object uObject[MAX_OBJECTS]

volatile _Queue uQueue
volatile char cCommandQueue[MAX_QUEUE_COMMANDS][NAV_MAX_BUFFER]
volatile char cStatusQueue[MAX_QUEUE_STATUS][NAV_MAX_BUFFER]

volatile char cRxBuffer[NAV_MAX_BUFFER]
volatile integer iSemaphore

volatile char cIPAddress[15]
volatile integer iIPConnected = false
volatile integer iIPAuthenticated

volatile integer iModuleEnabled

volatile integer iInitializing
volatile integer iInitializingObjectID

volatile integer iInitialized
volatile integer iCommunicating

volatile char cUserName[NAV_MAX_CHARS] = 'clearone'
volatile char cPassword[NAV_MAX_CHARS] = 'converge'

volatile char cObjectTag[MAX_OBJECT_TAGS][MAX_OBJECTS][NAV_MAX_CHARS]

volatile integer iDelayedRegisterRequired[MAX_OBJECTS]

volatile integer iRegistering
volatile integer iRegisteringObjectID
volatile integer iAllRegistered

volatile integer iReadyToInitialize

volatile integer iCommMode = COMM_MODE_TWO_WAY	//Default Two-Way

(***********************************************************)
(*               LATCHING DEFINITIONS GO BELOW             *)
(***********************************************************)
DEFINE_LATCHING

(***********************************************************)
(*       MUTUALLY EXCLUSIVE DEFINITIONS GO BELOW           *)
(***********************************************************)
DEFINE_MUTUALLY_EXCLUSIVE

(***********************************************************)
(*        SUBROUTINE/FUNCTION DEFINITIONS GO BELOW         *)
(***********************************************************)
(* EXAMPLE: DEFINE_FUNCTION <RETURN_TYPE> <NAME> (<PARAMETERS>) *)
(* EXAMPLE: DEFINE_CALL '<NAME>' (<PARAMETERS>) *)
define_function SendStringRaw(char cString[]) {
    NAVLog(NAVFormatStandardLogMessage(NAV_STANDARD_LOG_MESSAGE_TYPE_STRING_TO, dvPort, cString))
    send_string dvPort,"cString"
}

define_function SendString(char cString[]) {
    SendStringRaw("cString,NAV_CR,NAV_LF")
}

define_function AddToQueue(char cString[], integer iPriority) {
    stack_var integer iQueueWasEmpty
    iQueueWasEmpty = (!uQueue.iHasItems && !uQueue.iBusy)
    switch (iPriority) {
	case true: {	//Commands have priority over status requests
	    select {
		active (uQueue.iCommandHead == max_length_array(cCommandQueue)): {
		    if (uQueue.iCommandTail <> 1) {
			uQueue.iCommandHead = 1
			cCommandQueue[uQueue.iCommandHead] = cString
			uQueue.iHasItems = true
		    }
		}
		active (uQueue.iCommandTail <> (uQueue.iCommandHead + 1)): {
		    uQueue.iCommandHead++
		    cCommandQueue[uQueue.iCommandHead] = cString
		    uQueue.iHasItems = true
		}
	    }
	}
	case false: {
	    select {
		active (uQueue.iStatusHead == max_length_array(cStatusQueue)): {
		    if (uQueue.iStatusTail <> 1) {
			uQueue.iStatusHead = 1
			cStatusQueue[uQueue.iStatusHead] = cString
			uQueue.iHasItems = true
		    }
		}
		active (uQueue.iStatusTail <> (uQueue.iStatusHead + 1)): {
		    uQueue.iStatusHead++
		    cStatusQueue[uQueue.iStatusHead] = cString
		    uQueue.iHasItems = true
		}
	    }
	}
    }

    if (iQueueWasEmpty) { SendNextQueueItem(); }
}

define_function char[NAV_MAX_BUFFER] RemoveFromQueue() {
    if (uQueue.iHasItems && !uQueue.iBusy) {
	uQueue.iBusy = true
	select {
	    active (uQueue.iCommandHead <> uQueue.iCommandTail): {
		if (uQueue.iCommandTail == max_length_array(cCommandQueue)) {
		    uQueue.iCommandTail = 1
		}else {
		    uQueue.iCommandTail++
		}

		uQueue.cLastMess = cCommandQueue[uQueue.iCommandTail]
	    }
	    active (uQueue.iStatusHead <> uQueue.iStatusTail): {
		if (uQueue.iStatusTail == max_length_array(cStatusQueue)) {
		    uQueue.iStatusTail = 1
		}else {
		    uQueue.iStatusTail++
		}

		uQueue.cLastMess = cStatusQueue[uQueue.iStatusTail]
	    }
	}

	if ((uQueue.iCommandHead == uQueue.iCommandTail) && (uQueue.iStatusHead == uQueue.iStatusTail)) {
	    uQueue.iHasItems = false
	}

	return GetMess(uQueue.cLastMess)
    }

    return ''
}

define_function integer GetMessID(char cParam[]) {
    return atoi(NAVGetStringBetween(cParam,'<','|'))
}

define_function integer GetSubscriptionMessID(char cParam[]) {
    return atoi(NAVGetStringBetween(cParam,'[','*'))
}

define_function char[NAV_MAX_BUFFER] GetMess(char cParam[]) {
    return NAVGetStringBetween(cParam,'|','>')
}

define_function InitializeObjects() {
    stack_var integer x
    if (!iInitializing) {
	for (x = 1; x <= length_array(vdvCommObjects); x++) {
	    if (uObject[x].iRegistered && !uObject[x].iInitialized) {
		iInitializing = true
		send_string vdvCommObjects[x],"'INIT<',itoa(x),'>'"
		iInitializingObjectID = x
		break
	    }

	    if (x == length_array(vdvCommObjects) && !iInitializing) {
		iInitializingObjectID = x
		iInitialized = true
	    }
	}
    }
}

define_function GoodResponse() {
    uQueue.iBusy = false
    NAVTimelineStop(TL_QUEUE_FAILED_RESPONSE)

    uQueue.iStrikeCount = 0
    uQueue.iResendLast = false
    SendNextQueueItem()
}

define_function SendNextQueueItem() {
    stack_var char cTemp[NAV_MAX_BUFFER]

    if (uQueue.iResendLast) {
	uQueue.iResendLast = false
	cTemp = GetMess(uQueue.cLastMess)
    }else {
	cTemp= RemoveFromQueue()
    }

    if (length_array(cTemp)) {
	SendString(cTemp)

	switch (iCommMode) {
	    case COMM_MODE_TWO_WAY: {
		timeline_create(TL_QUEUE_FAILED_RESPONSE,ltQueueFailedResponse,length_array(ltQueueFailedResponse),TIMELINE_ABSOLUTE,TIMELINE_ONCE)
	    }
	    case COMM_MODE_ONE_WAY: {
		wait 5 GoodResponse()	//Move on if in one way mode
	    }
	}
    }
}

define_event timeline_event[TL_QUEUE_FAILED_RESPONSE] {
    if (uQueue.iBusy) {
	if (uQueue.iStrikeCount < 3) {
	    uQueue.iStrikeCount++
	    uQueue.iResendLast = true
	    SendNextQueueItem()
	}else {
	    iCommunicating = false
	    Reset()
	}
    }
}

define_function Reset() {
    ReInitializeObjects()
    InitializeQueue()
}

define_function ReInitializeObjects() {
    stack_var integer x
    iInitializing = false
    iInitialized = false
    iInitializingObjectID = 1
    for (x = 1; x <= length_array(uObject); x++) {
	uObject[x].iInitialized = false
    }
}

define_function InitializeQueue() {
    uQueue.iBusy = false
    uQueue.iHasItems = false
    uQueue.iCommandHead = 1
    uQueue.iCommandTail = 1
    uQueue.iStatusHead = 1
    uQueue.iStatusTail = 1
    uQueue.iStrikeCount = 0
    uQueue.iResendLast = false
    uQueue.cLastMess = "''"
}

define_function Process() {
    stack_var char cTemp[NAV_MAX_BUFFER]
    iSemaphore = true
    while (length_array(cRxBuffer) && NAVContains(cRxBuffer,"NAV_LF")) {
	cTemp = remove_string(cRxBuffer,"NAV_LF",1)
	if (length_array(cTemp)) {
	    stack_var integer iResponseMessID
	    NAVLog(NAVFormatStandardLogMessage(NAV_STANDARD_LOG_MESSAGE_TYPE_PARSING_STRING_FROM, dvPort, cTemp))
	    cTemp = NAVStripCharsFromRight(cTemp, 3)	//Removes |CR,LF
	    select {
		active (NAVContains(uQueue.cLastMess,'HEARTBEAT')): {
		    if (!iCommunicating) {
			iCommunicating = true
			//SendString("NAV_ESC,'3CV',NAV_CR")	//Set Verbose Mode
		    }

		    if (iCommunicating && !iInitialized && iReadyToInitialize) {
			InitializeObjects()
		    }
		}
		active (1): {
		    stack_var integer x
		    stack_var integer i
		    for (x = 1; x <= length_array(vdvCommObjects); x++) {
			for (i = 1; i <= MAX_OBJECT_TAGS; i++) {
			    if (NAVContains(cTemp,cObjectTag[i][x])) {
				send_string vdvCommObjects[x],"'RESPONSE_MSG<',cTemp,'>'"
				i = (MAX_OBJECT_TAGS + 1)
				x = (MAX_OBJECTS + 1)
			    }
			}
		    }
		}
	    }

	    GoodResponse()
	}
    }

    iSemaphore = false
}




define_function MaintainIPConnection() {
    if (!iIPConnected) {
	NAVClientSocketOpen(dvPort.port,cIPAddress,NAV_TELNET_PORT,IP_TCP)
    }
}

(***********************************************************)
(*                STARTUP CODE GOES BELOW                  *)
(***********************************************************)
DEFINE_START
create_buffer dvPort,cRxBuffer
iModuleEnabled = true
rebuild_event()
Reset()


(***********************************************************)
(*                THE EVENTS GO BELOW                      *)
(***********************************************************)
DEFINE_EVENT
data_event[dvPort] {
    online: {
	if (iModuleEnabled && data.device.number <> 0) {
	    send_command data.device,"'SET MODE DATA'"
	    send_command data.device,"'SET BAUD 19200,N,8,1 485 DISABLE'"
	    send_command data.device,"'B9MOFF'"
	    send_command data.device,"'CHARD-0'"
	    send_command data.device,"'CHARDM-0'"
	    send_command data.device,"'HSOFF'"
	}

	if (iModuleEnabled && data.device.number <> 0 && iCommMode == COMM_MODE_TWO_WAY) {
	    timeline_create(TL_HEARTBEAT,ltHeartbeat,length_array(ltHeartbeat),TIMELINE_ABSOLUTE,TIMELINE_REPEAT)
	}

	if (data.device.number == 0) {
	    iIPConnected = true
	    SendString(cUserName)
	    SendString(cPassword)
	}
    }
    string: {
	if (iModuleEnabled) {
	    NAVLog(NAVFormatStandardLogMessage(NAV_STANDARD_LOG_MESSAGE_TYPE_STRING_TO, data.device, data.text))
	    select {
		//active (NAVContains(cRxBuffer,"'user:'")): {
		    //cRxBuffer = "''"; SendString(cUserName);
		//}
		//active (NAVContains(cRxBuffer,"'pass:'")): {
		    //cRxBuffer = "''"; SendString(cPassword);
		//}
		active (1): {
		    if (!iSemaphore && iCommMode == COMM_MODE_TWO_WAY) { Process() }
		}
	    }
	}
    }
    offline: {
	if (data.device.number == 0) {
	    NAVClientSocketClose(dvPort.port)
	    iIPConnected = false
	    iIPAuthenticated = false
	    iCommunicating = false
	    NAVTimelineStop(TL_HEARTBEAT)
	}
    }
    onerror: {
	if (data.device.number == 0) {
	    //iIPConnected = false
	    //iIPAuthenticated = false
	    //iCommunicating = false
	    //if (timeline_active(TL_HEARTBEAT)) {
	//	NAVTimelineStop(TL_HEARTBEAT)
	    //}
	}
    }
}

data_event[vdvControl] {
    command: {
        stack_var char cCmdHeader[NAV_MAX_CHARS]
	stack_var char cCmdParam[2][NAV_MAX_CHARS]
	if (iModuleEnabled) {
	    NAVLog(NAVFormatStandardLogMessage(NAV_STANDARD_LOG_MESSAGE_TYPE_COMMAND_FROM, data.device, data.text))
	    cCmdHeader = DuetParseCmdHeader(data.text)
	    cCmdParam[1] = DuetParseCmdParam(data.text)
	    cCmdParam[2] = DuetParseCmdParam(data.text)
	    switch (cCmdHeader) {
		case 'PROPERTY': {
		    switch (cCmdParam[1]) {
			case 'IP_ADDRESS': {
			    cIPAddress = cCmdParam[2]
			    timeline_create(TL_IP_CHECK,ltIPCheck,length_array(ltIPCheck),timeline_absolute,timeline_repeat)
			}
			case 'USER_NAME': {
			    cUserName = cCmdParam[2]
			}
			case 'PASSWORD': {
			    cPassword = cCmdParam[2]
			}
			case 'COMM_MODE': {
			    switch (cCmdParam[2]) {
				case 'ONE-WAY': {
				    iCommMode = COMM_MODE_ONE_WAY
				    NAVTimelineStop(TL_HEARTBEAT)

				    NAVCommandArray(vdvCommObjects,'PROPERTY-COMM_MODE,ONE-WAY')
				}
				case 'TWO-WAY': {
				    iCommMode = COMM_MODE_TWO_WAY
				    if (!timeline_active(TL_HEARTBEAT)) {
					timeline_create(TL_HEARTBEAT,ltHeartbeat,length_array(ltHeartbeat),TIMELINE_ABSOLUTE,TIMELINE_REPEAT)
				    }

				    NAVCommandArray(vdvCommObjects,'PROPERTY-COMM_MODE,TWO-WAY')
				}
			    }
			}
		    }
		}
		case 'INIT': {
		    stack_var integer x
		    for (x = 1; x <= length_array(vdvCommObjects); x++) {
			send_string vdvCommObjects[x],"'REGISTER<',itoa(x),'>'"
			NAVLog("'AUDAC_SMQ_REGISTER_SENT<',itoa(x),'>'")
		    }

		    //timeline_create(TL_REGISTER,ltRegister,length_array(ltRegister),TIMELINE_ABSOLUTE,TIMELINE_REPEAT)

		    //iReadyToInitialize = true
		    //if (data
		    //timeline_create(TL_HEARTBEAT,ltHeartbeat,length_array(ltHeartbeat),TIMELINE_ABSOLUTE,TIMELINE_REPEAT)
		}
	    }
	}
    }
}

data_event[vdvCommObjects] {
    online: {
	//if (get_last(vdvCommObjects) == length_array(vdvCommObjects)) {
	  //  timeline_create(TL_REGISTER,ltRegister,length_array(ltRegister),TIMELINE_ABSOLUTE,TIMELINE_REPEAT)
	//}
	send_string data.device,"'REGISTER<',itoa(get_last(vdvCommObjects)),'>'"
	NAVLog("'AUDAC_SMQ_REGISTER<',itoa(get_last(vdvCommObjects)),'>'")
    }
    command: {
	if (iModuleEnabled) {
	    stack_var char cCmdHeader[NAV_MAX_CHARS]
	    stack_var integer iResponseObjectMessID
	   NAVLog(NAVFormatStandardLogMessage(NAV_STANDARD_LOG_MESSAGE_TYPE_COMMAND_FROM, data.device, data.text))
	    cCmdHeader = DuetParseCmdHeader(data.text)
	    switch (cCmdHeader) {
		case 'COMMAND_MSG': { AddToQueue("cCmdHeader,data.text",true) }
		case 'POLL_MSG': { AddToQueue("cCmdHeader,data.text",false) }
		case 'RESPONSE_OK': {
		    if (NAVGetStringBetween(data.text,'<','>') == NAVGetStringBetween(uQueue.cLastMess,'<','>')) {
			GoodResponse()
		    }
		}
		case 'INIT_DONE': {
		    iInitializing = false
		    iResponseObjectMessID = atoi(NAVGetStringBetween(data.text,'<','>'))
		    uObject[iResponseObjectMessID].iInitialized = true
		    InitializeObjects()
		    if (get_last(vdvCommObjects) == length_array(vdvCommObjects)) {
			//Init is Done!
			send_string vdvControl,"'INIT_DONE'"
		    }
		}
		case 'REGISTER': {
		    //iRegistering = false
		    if (NAVContains(data.text,'|')) {
			iResponseObjectMessID = atoi(NAVGetStringBetween(data.text,'<','|'))
			if (NAVContains(data.text,'*')) {
			    stack_var integer x
			    x = 1
			    remove_string(data.text,'|',1)
			    while (length_array(data.text) &&  (NAVContains(data.text,'*') || NAVContains(data.text,'>'))) {
				select {
				    active (NAVContains(data.text,'*')): {
					cObjectTag[x][iResponseObjectMessID] = NAVStripCharsFromRight(remove_string(data.text,'*',1),1)
					x++
				    }
				    active (NAVContains(data.text,'>')): {
					cObjectTag[x][iResponseObjectMessID] = NAVStripCharsFromRight(remove_string(data.text,'>',1),1)
				    }
				}
			    }
			}else {
			    cObjectTag[1][iResponseObjectMessID] = NAVGetStringBetween(data.text,'|','>')
			}

			uObject[iResponseObjectMessID].iRegistered = true
		    }else {
			iResponseObjectMessID = atoi(NAVGetStringBetween(data.text,'<','>'))
			uObject[iResponseObjectMessID].iRegistered = true
		    }

		    if (get_last(vdvCommObjects) == length_array(vdvCommObjects) && !iInitialized) {
			iReadyToInitialize = true
		    }
		   // RegisterObjects()

		   //Start init process if one-way
		    if (get_last(vdvCommObjects) == length_array(vdvCommObjects) && (iCommMode == COMM_MODE_ONE_WAY) && !iInitialized) {
			InitializeObjects()
		    }
		}
	    }
	}
    }
}

timeline_event[TL_HEARTBEAT] {
    if (!uQueue.iHasItems && !uQueue.iBusy && (iCommMode == COMM_MODE_TWO_WAY)) {
	AddToQueue("'POLL_MSG<HEARTBEAT|#|Q001|web|GTE|0|U|>'",false)
    }
}

timeline_event[TL_IP_CHECK] { MaintainIPConnection() }


timeline_event[TL_REGISTER] {
    stack_var integer x
    x = type_cast(timeline.repetition + 1)
    send_string vdvCommObjects[x],"'REGISTER<',itoa(x),'>'"
    NAVLog("'AUDAC_SMQ_REGISTER_SENT<',itoa(x),'>'")
    if (x == length_array(vdvCommObjects)) {
	timeline_kill(timeline.id)
    }
}

timeline_event[TL_NAV_FEEDBACK] {
    if (iModuleEnabled) {
	[vdvControl,NAV_IP_CONNECTED]	= (iIPConnected && iIPAuthenticated)
	[vdvControl,DEVICE_COMMUNICATING] = (iCommunicating)
	[vdvControl,DATA_INITIALIZED] = (iInitialized)
    }
}

(***********************************************************)
(*                     END OF PROGRAM                      *)
(*        DO NOT PUT ANY CODE BELOW THIS COMMENT           *)
(***********************************************************)

