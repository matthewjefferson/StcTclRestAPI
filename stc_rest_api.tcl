###############################################################################
#
#                     Spirent TestCenter Tcl REST Front-end
#                         by Spirent Communications
#
#   Date: December 15, 2015
# Author: Matthew Jefferson
#
# Description: This library provides a Tcl front-end for the Spirent TestCenter
#              REST API. It is intended to allow a user to execute traditonal
#              Spirent TestCenter API scripts with little to no modification.
#
###############################################################################
#
# Modification History
# Version  Modified
# 0.1.0    12/15/2015 by Matthew Jefferson
#           -Began work on package.
#
# 0.2.0    01/07/2016 by Matthew Jefferson
#           -Nearing completion. I would consider this to be the beta.
#
# 0.2.1    07/22/2016 by Matthew Jefferson
#           -Change the default HTTP port to 80. 
#           -Apply now needs the Content-Length header (even though it's zero).
#           -Added the automatic upload/download for those commands that deal
#            with files.
#            NOTE: Not all commands are supported. Each individual command has
#                  to be added. If there is one that is not supported, some
#                  additional work will be required.
#
# 0.3.0    05/02/2018 by Matthew Jefferson
#           -Added support for the stcweb ReST server.
#
###############################################################################

set __package_version__ 0.3
set __package_build__   ${__package_version__}.1

###############################################################################
# Copyright (c) 2015 SPIRENT COMMUNICATIONS OF CALABASAS, INC.
# All Rights Reserved
#
#                SPIRENT COMMUNICATIONS OF CALABASAS, INC.
#                            LICENSE AGREEMENT
#
#  By accessing or executing this software, you agree to be bound by the terms
#  of this agreement.
#
# Redistribution and use of this software in source and binary forms, with or
# without modification, are permitted provided that the following conditions
# are met:
#  1. Redistribution of source code must retain the above copyright notice,
#     this list of conditions and the following disclaimer.
#  2. Redistribution's in binary form must reproduce the above copyright notice.
#     This list of conditions and the following disclaimer in the documentation
#     and/or other materials provided with the distribution.
#  3. Neither the name SPIRENT, SPIRENT COMMUNICATIONS, SMARTBITS, SPIRENT
#     TESTCENTER, AVALANCHE NEXT, LANDSLIDE, nor the names of its contributors
#     may be used to endorse or promote products derived from this software
#     without specific prior written permission.
#
# This software is provided by the copyright holders and contributors [as is]
# and any express or implied warranties, including, but not limited to, the
# implied warranties of merchantability and fitness for a particular purpose
# are disclaimed. In no event shall the Spirent Communications of Calabasas,
# Inc. Or its contributors be liable for any direct, indirect, incidental,
# special, exemplary, or consequential damages (including, but not limited to,
# procurement of substitute goods or services; loss of use, data, or profits;
# or business interruption) however caused and on any theory of liability,
# whether in contract, strict liability, or tort (including negligence or
# otherwise) arising in any way out of the use of this software, even if
# advised of the possibility of such damage.
#
###############################################################################

package provide stcrestapi $__package_version__

###############################################################################
####
####    Global Variables
####
###############################################################################
namespace eval ::stc {
    # Global Namespace Variables
    variable version     $__package_version__
    variable fullversion $__package_build__

    variable filepath [file dirname [info script]]
    variable libpath  [file normalize [file join $::stc::filepath "./lib/tcllib-1.17/modules"]]

    variable state
    set state(usingrest) 0
    set state(logfile)   ""
    set state(verbose)   0          ;# Set to 1 to output log messages to STDOUT.
    set state(procs)     ""
    set state(pid)       [pid]
    set state(pwd)       [pwd]

    # The sessions dictionary contains contains the information for all initialized sessions.
    variable sessions

    # Export public procs (which all begin with a lower-case letter).
    namespace export {[a-z]*}
}


###############################################################################
####
####    Packages
####
###############################################################################
# Load the TEPAM package. It is included with TclLib, but the included version is up-to-date.
lappend ::auto_path $::stc::libpath

# This code is required to for Tcl to learn about all available packages.
# Without this, the "package versions" command won't work.
eval [package unknown] Tcl [package provide Tcl]

set tepamversion [package require tepam]
if { [package vcompare $tepamversion "0.5"] < 0 } {
    error "The loaded Tcllib TEPAM package version ($tepamversion) is not supported. Please upgrade to at least version 0.5."
}
unset tepamversion



###############################################################################
####
####    Public Procedures
####
###############################################################################

tepam::procedure ::stc::init {
    -description "Load the Spirent TestCenter API. This procedure can be used
                  to load the native API, or the REST API. It also includes
                  options for using a Lab Server.
                  NOTE: If the native Spirent TestCenter API is loaded, all of
                  procedures in this library are unloaded from memory. This is
                  to avoid name collisions with the native commands.
                  Returns the version that was loaded."
    -named_arguments_first 0
    -args {
        {-version
            -description "Load this specific version of the Spirent TestCenter API.
                          If not specified, and the -chassisaddress is specified, the 
                          version will be determined automatically; otherwise,
                          the latest available version will be loaded."
            -default     ""}    
        {-chassisaddress 
            -description "Use this argument if you want to automatically determine
                          the Spirent TestCenter API version to load." 
            -default     ""}                        
        {-userest
            -description "Use this flag to use the REST API back-end. This requires 
                          the use of a Lab Server."
            -type        "none"}
        {-serveraddress 
            -description "Use this argument if you want to use a Lab Server, and it is
                          required if '-userest' is used. If '-userest' is specified, 
                          'serveraddress' can also include the TCP port (eg: 10.1.1.1:80).
                          80 is the default Tcp port." 
            -default     ""}
        {-sessionname 
            -description "Name of the lab server session. Only used when -labserverip
                          is specified." 
            -default     ""}
        {-username
            -description "Username for the lab server session. Only used when -labserverip
                          is specified." 
            -default     ""}
        {-reset 
            -description "Delete any existing lab server session that matches the specified 
                          session name and userid. Only used when -labserverip is specified." 
            -type        "none"}          
        {-loglevel
            -description "All log messages with a priotity equal to, or higher than, the
                          specified level will be included in the log file."
            -choices     "ERROR WARN INFO DEBUG"
            -default     "INFO"} 
        {-verbose
            -description "Output log messages to STDOUT."
            -type        "none"}                          
    }
} {

    if { $sessionname eq "" } {
        set sessionname "Session[pid]"
    }

    if { $username eq "" } {
        # Attempt to determine the default ownerid.
        if { $::tcl_platform(platform) eq "unix" } {
            set username $::env(USER)
        } else {
            set username $::env(USERNAME)
        }
    }

    if { $userest } {
        # Use the REST API.
        set loadedversion "1.0.0"

        package require http
        package require json

        # Start by initializing logging.

        if { $verbose } {
            set ::stc::state(verbose) 1
        }
        InitLogging $loglevel

        # Store a list of procedures defined by this library. This is needed for logging.
        set ::stc::state(procs) [info procs ::stc::*]

        if { $serveraddress eq "" } {
            error "A lab server is required for the REST API."
        }                

        if { $reset } {
            stc::setSession $serveraddress -sessionname $sessionname -username $username -reset
        } else {
            stc::setSession $serveraddress -sessionname $sessionname -username $username
        }

        # Return the Spirent TestCenter version that we are connected to.
        set version [stc::get "system1" -version]
        set major [lindex [split $version .] 0]
        set minor [lindex [split $version .] 1]
        set build [lindex [split $version .] 2]
        
        set loadedversion $major.$minor

        # This flag is for the user only. 
        set ::stc::state(usingrest)  1     

        Log "INFO" "fmwk.bll.msg" "Connected to the server $serveraddress ($sessionname - $username)..."
        Log "INFO" "fmwk.bll.msg" "Using Spirent TestCenter version $version"

    } else {        
        # Load the native Spirent TestCenter API.

        # Delete all of the REST-based stc commands to prevent them from interfering with the
        # native Spirent TestCenter API.
        foreach procedure [info proc ::stc::*] {
            if { ! [string match $procedure "::stc::init"] } {
                rename $procedure ""
            }
        }

        # First determine the version of Spirent TestCenter to load. We can find this information from a chassis.
        if { $chassisaddress ne "" && $version eq "" } {

            # The user has requested that we automatically discover the version to use.
            # Connect to the specified chassis or lab server and recover the version information.
            
            set filename [file join $::stc::filepath "stc_get_version.tcl"]

            # Be sure to set the TCLLIBPATH so that the discovery script can find at least
            # one version of Spirent TestCenter to use.
            set ::env(TCLLIBPATH) $::auto_path

            # The following would be the most efficient code to capture the information,
            # however, it appears that a known issue causes the process to hang when the
            # exec command and error output are not redirected.
            #set version [exec tclsh $filename $chassisaddress]

            # This is a work-around for the hang issue for the previous command.
            set output "stc_get_version_[pid].log"
            exec >& $output tclsh $filename $chassisaddress
            
            # Extract the version information from the output file.
            set fh [open $output r]
            set version ""
            regexp {version=(.+)} [read $fh] -> version
            close $fh
            catch {file delete -force $output}
            # End work-around.

            set stcapiversion ""

            if { $version eq "" } {
                puts "WARNING: Unable to determine the firmware version for the chassis $chassisaddress."
            } else {

                set major [lindex [split $version .] 0]
                set minor [lindex [split $version .] 1]
                set build [lindex [split $version .] 2]

                set stcapiversion $major.$minor
            }

        } elseif { $version ne "" } {
            # Just use the specified version.
            set stcapiversion $version
        } else {
            set stcapiversion ""
        }

        if { $version eq "" } {
            # Load the latest version of the package.
            set loadedversion [package require SpirentTestCenter]
        } else {
            # Try to load the specified version of the package.
            set loadedversion [package require -exact SpirentTestCenter $stcapiversion]
        }

        # Connect to the lab server if the user specified one.
        if { $serveraddress ne "" } {

            # First, determine if there is an existing session with the same name/owner.
            # If there is, attempt to connect to it. If there isn't, create a new one.

            set sessionid "$sessionname - $username"

            # Determine if the session already exists.
            stc::perform CSServerConnect -host $serveraddress
            set sessionexists 0
            foreach session [stc::get system1.csserver -children-CSTestSession] {
                if { [string match [stc::get $session -Name] $sessionid] } {
                    set sessionexists 1
                    break
                }
            }

            if { $sessionexists && $reset } {
                stc::perform CSStopTestSessionCommand -TestSession $session

                # Next, you need to clean up the terminated session.
                if { [stc::get $session -TestSessionState] eq "TERMINATED" } {
                    stc::perform CSDestroyTestSessionCommand -TestSession $session
                } else {
                    stc::log ERROR "Unable to delete the session, because it is not in the TERMINATED state ([stc::get $targetsession -TestSessionState])."
                }

                set sessionexists 0
            }

            # We need to disconnect from the server BEFORE we connect to the session.
            # It may not be necessary to disconnect, but we cannot do it after the CSTestSessionConnect.
            stc::perform CSServerDisconnect

            if { $sessionexists } {
                # Just connect to the existing session.                
                stc::log INFO "Connecting to the session $serveraddress : $sessionid..."
                stc::perform CSTestSessionConnect -Host            $serveraddress \
                                                  -TestSessionName $sessionname   \
                                                  -OwnerId         $username
            } else {
                stc::log INFO "Creating the session $serveraddress : $sessionid..."
                stc::perform CSTestSessionConnect -Host                 $serveraddress \
                                                  -CreateNewTestSession TRUE           \
                                                  -TestSessionName      $sessionname   \
                                                  -OwnerId              $username
            }
        }
    } ;# End Using the native Spirent TestCenter API

    return $loadedversion
}

#==============================================================================
tepam::procedure ::stc::setSession {
    -description "Set the current Session ID. This session will then be used
                  for all subsequent calls. The Session ID is returned. If the
                  Session ID is already known, then it will not be validated
                  against the list of sessions running on the Lab Server, unless
                  the -validate flag is used.
                  Returns a dictionary for the current session."
    -named_arguments_first 0
    -args {
        {serveraddress
            -description "The IP address of the Spirent REST API server. You
                          may also specify the TCP port (default is 80).
                          eg: 10.1.1.1:80"}          
        {-sessionname 
            -description "Sessionsname for the lab server session. The default
                          is TclRESTSession<pid>."
            -default     ""}
        {-username
            -description "Username for the lab server session."
            -default     ""}                            
        {-sessionid
            -description "The desired Session ID on the Lab Server. This is 
                          a combination of the sessionname and username 
                          (sessionname - username). If specified, it will 
                          override -sessionname and -username."
            -default     ""}
        {-novalidation
            -description "Normally, when you switch to a known existing session, 
                          that session is verified to exist on the server. Use
                          this flag to skip that validation. This can be used
                          when performance is a priority." 
            -type        "none"}               
        {-reset 
            -description "If specified and the specified session already exists, then
                          the existing session will be terminated, and a new session 
                          created. If not specified, and the session already exists,
                          then the existing session will be left alone."
            -type        "none"}
        {-resetwaittime
            -description "Used with the -reset flag. The time (in seconds) to wait for
                          an existing session to be terminated before creating a new one."
            -type        integer                          
            -default     10}                        
    }    
} {
    variable ::stc::sessions

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }
    Log $loglevel "user.scripting.rest" "stc::setSession $args"    

    # First, determine the session ID.
    if { $sessionid eq "" } {
        if { $sessionname eq "" } {
            set sessionname "TclRestSession[pid]"
        }

        if { $username eq "" } {
            # Attempt to determine the default ownerid.
            if { $::tcl_platform(platform) eq "unix" } {
                set username $::env(USER)
            } else {
                set username $::env(USERNAME)
            }
        }

        set sessionid "$sessionname - $username"    
    } else {
        set username [lindex [split $sessionid "-"] end]
        set username [string trim $username]

        # We have to extract the session name. Do this by deleting the username.
        set sessionname ""
        regsub -nocase " - $username" $sessionid {} sessionname
    }
    
    # Now determine the full server IP and TCP port.
    set server [GetFullAddress $serveraddress]
    set serverip      [dict get $server "address"]
    set serverport    [dict get $server "tcpport"]
    set serveraddress [dict get $server "fulladdress"]

    # If the session is unknown, check the REST API server to see if we need to create a new session.
    if { ! [info exists sessions] || ! [dict exists $sessions $serverip $sessionid] || $reset } {        
        # This process has never dealt with this session. See if it exists on the server.

        set sessionexists [::stc::sessionExists $serveraddress $sessionid]

        if { $sessionexists && $reset } {   
             deleteSession $serveraddress $sessionid
             # It takes some time for the session to be terminated.   
             after [expr $resetwaittime * 1000]            
             set sessionexists 0
        }

        if { ! $sessionexists } {
            # We need to create the session on the lab server.
            set payload [list "userid=$username&sessionname=$sessionname"]
            set jsonresponse [Execute "POST" $serveraddress "/stcapi/sessions" -payload $payload]
            #set response [::json::json2dict $jsonresponse]        
            #set returnsession [dict get $response "session_id"]        
        }
    } else {        
        # The session is known by the client, and it should already exist.
        if { ! $novalidation && ! [::stc::sessionExists $serveraddress $sessionid] } {
            # The session should exist, but it doesn't. This can happen when the session
            # is terminated by another user/process.
            error "The session '$serveraddress $sessionid' does not exist."
        }
    }

    # Save the TCP port used by this server. If the TCP port was already defined,
    # this will overwrite that value.
    dict set sessions $serverip "tcpport" $serverport

    # Save this session so that we know that it exists on the server.
    dict set sessions $serverip $sessionid 1 

    # The current session is a dictionary that contains the 'address', 'tcpport',
    # 'fulladdress', 'sessionid', 'sessionname' and 'username'.
    set session [dict create "address"     $serverip             \
                             "tcpport"     $serverport           \
                             "fulladdress" $serverip:$serverport \
                             "sessionid"   $sessionid            \
                             "sessionname" $sessionname          \
                             "username"    $username]

    dict set sessions "current" $session

    Log $loglevel "user.scripting.rest" "return $session"

    return $session
}

#==============================================================================
tepam::procedure ::stc::deleteSession {
    -description "Delete the specified session on the Lab Server. If you do 
                  not specify a session ID, then the current session will
                  be terminated."
    -named_arguments_first 0
    -args {
        {serveraddress
            -description "The IP address of the Spirent REST API server. You
                          may also specify the TCP port (default is 80).
                          eg: 10.1.1.1:80"
            -default     ""}   
        {sessionid
            -description "Sessionsname for the lab server session."
            -default     ""}
    }
} {
    variable ::stc::sessions

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }
    Log $loglevel "user.scripting.rest" "stc::deleteSession $args"

    if { $serveraddress eq "" || $sessionid eq "" } {
        set session [::stc::getCurrentSession]           
        set serveraddress [dict get $session "fulladdress"]     
        set sessionid     [dict get $session "sessionid"]
    }

    if { $serveraddress eq "" } {
        error "You must specify a Lab Server address."
    }

    if { $sessionid eq "" } {
        error "You must specify a Lab Server session ID."
    }

    set server [GetFullAddress $serveraddress]
    set serverip      [dict get $server "address"]
    set serveraddress [dict get $server "fulladdress"]

    if { [::stc::sessionExists $serveraddress $sessionid] } {
        set sessionencode [::http::formatQuery $sessionid]     
        Execute "DELETE" $serveraddress "/stcapi/sessions/$sessionencode"
    }

    if {  [info exists sessions] && [dict exists $sessions $serverip $sessionid] } {
        # Update the list of known sessions by removing the one we just deleted.

        set sessions [dict remove $sessions $serverip $sessionid]
        
        # Check to see if the current session is the same as the one that we just deleted.
        set session [dict get $sessions "current"]
        if { $serverip eq [dict get $session "address"] && $sessionid eq [dict get $session "sessionid"] } {
            # The current session is the one that we just deleted, so unset it.
            # This is a curious state. I don't want to automatically select a new
            # session, as it is an opaque process to the user.
            # If the user tries to do something without invoking the "setSession" command first, an exception
            # may be thrown.
            set sessions [dict remove $sessions "current"]
        }
    }

    Log $loglevel "user.scripting.rest" "return"

    return
}        

#==============================================================================
tepam::procedure ::stc::getSessions {
    -description "Returns a list of sessions on the specified lab server. This
                  also updates the sessions dictionary."
    -named_arguments_first 0
    -args {
        {serveraddress
            -description "The IP address of the Spirent REST API server. You
                          may also specify the TCP port (default is 80).
                          eg: 10.1.1.1:80"}   
    }
} {
    variable ::stc::sessions

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }
    Log $loglevel "user.scripting.rest" "stc::getSessions $args"

    set server [GetFullAddress $serveraddress]
    set serveraddress [dict get $server "fulladdress"]
    set serverip      [dict get $server "address"]

    set jsonresponse [Execute "GET" $serveraddress "/stcapi/sessions"]

    set response [::json::json2dict $jsonresponse]

    foreach sessionid $response {
        dict set sessions $serverip $sessionid 1
    }

    Log $loglevel "user.scripting.rest" "return $response"

    return $response
}

#==============================================================================
tepam::procedure ::stc::sessionExists {
    -description "Returns True if the specified session exists, False otherwise."
    -named_arguments_first 0
    -args {
        {serveraddress
            -description "The IP address of the Spirent REST API server. You
                          may also specify the TCP port (default is 80).
                          eg: 10.1.1.1:80"}   
        {sessionid
            -description "Session ID of the lab server session."}            
    }
} {

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::sessionExists $args"  

    if { 1 } {
        # The stcweb version of the ReST API doesn't seem to support the HEAD method.
        set sessionexists "False"
        foreach session [::stc::getSessions $serveraddress] {
            if { $session eq $sessionid } {
                set sessionexists "True"
                break
            }            
        }

        if { $sessionexists } {
            Log $loglevel "user.scripting.rest" "return True"
            return "True"                
        } else {
            Log $loglevel "user.scripting.rest" "return False"
            return "False"
        }

    } else {
        # This is the original way to determine if a session exists.
        # This works fine on Lab Server, but not on the Windows-based stcweb.
        set server [GetFullAddress $serveraddress]    
        set serveraddress [dict get $server "fulladdress"]    

        set sessionencode [::http::formatQuery $sessionid]

        if { [catch {Execute "HEAD" $serveraddress "/stcapi/sessions/$sessionencode"} errmsg erropt] } {    
            if { $::errorCode == 404 } {
                # We expect an errorcode 404 if the session doesn't exist.
                Log $loglevel "user.scripting.rest" "return False"
                return "False"
            } else {
                Log "ERROR" "user.scripting.rest" $errmsg
                error $errmsg
            }
        } else {
            Log $loglevel "user.scripting.rest" "return True"
            return "True"
        }        
    }
}

#==============================================================================
tepam::procedure ::stc::getCurrentSession {
    -description "Returns a dictionary containing the current server 'address',
                  'fulladdress', 'tcpport', 'sessionid', 'sessionname' and 
                  'username'."
    -named_arguments_first 0
} {
    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::getCurrentSession"

    if { [dict exists $::stc::sessions "current"] } {
        set response [dict get $::stc::sessions "current"]
        Log $loglevel "user.scripting.rest" "return $response"
        return $response
    } else {
        Log "ERROR" "user.scripting.rest" "There are no sessions currently defined."
        error "There are no sessions currently defined."
    }
}

#==============================================================================
tepam::procedure ::stc::getSessionInfo {
    -description "Returns the current Session ID."
    -named_arguments_first 0
    -args {
        {serveraddress
            -description "The IP address of the Spirent REST API server. You
                          may also specify the TCP port (default is 80).
                          eg: 10.1.1.1:80"}   
        {sessionid
            -description "Session ID of the lab server session."}        
    }
} {
    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::getSessionInfo $args"

    set server [GetFullAddress $serveraddress]
    set serveraddress [dict get $server "fulladdress"]

    set response ""
    set sessionencode [::http::formatQuery $sessionid]
    set jsonresponse [Execute "GET" $serveraddress "/stcapi/sessions/$sessionencode"]
    set response [::json::json2dict $jsonresponse]     

    Log $loglevel "user.scripting.rest" "return $response"   

    return $response
}

#==============================================================================
tepam::procedure ::stc::get {
    -description "Returns the value(s) of one or more object attributes or a set of object handles."
    -named_arguments_first 0
    -args {
        {object
            -description "The object handle."}
        {attributelist 
            -type        "string"
            -default     ""
            -multiple
        }
    }
} {
    Log "INFO" "user.scripting" "stc::get $args"

    set attributedict [FormatAttributes $attributelist]
    set attributes     [dict get $attributedict "attributes"]
    set attributecount [dict get $attributedict "count"]

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    set jsonresponse [Execute "GET" $serveraddress "/stcapi/objects/$object?$attributes" -headers [list "X-STC-API-Session" $sessionid]]

    # Convert the JSON-formatted response back to Tcl style.
    set reponse ""
    if { $jsonresponse ne "" && [::json::validate $jsonresponse] } {        
        set responsedict [::json::json2dict $jsonresponse]

        if { $attributecount != 1 } {
            # If only a single attribute was specified, then the response
            # will only contain the value for that attribute, and not the
            # attribute label itself.

            # Add the leading dash (-) to all attributes.
            dict for {key value} $responsedict {
                lappend response -$key $value
            }
        } else {
            # Only one attribute was specified, so only return the value.
            set response $responsedict
        }            
    } else {
        set response $jsonresponse
    }

    Log "INFO" "user.scripting" "return $response"

    return $response
}


#==============================================================================
tepam::procedure ::stc::config {
-description "Sets or modifies one or more object attributes, or a relation."
    -named_arguments_first 0
    -args {
        {object
            -description "The object handle."}
        {attributelist 
            -type        "string"
            -default     ""
            -multiple
        }
    }
} {

    Log "INFO" "user.scripting" "stc::config $args"

    set attributes [FormatAttributesWithValues $attributelist]

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }
    
    set response [Execute "PUT" $serveraddress "/stcapi/objects/$object" -headers [list "X-STC-API-Session" $sessionid] -payload $attributes]

    # Actually, config doesn't actually have a response.
    Log "INFO" "user.scripting" "return $response"

    return $response
}

#==============================================================================
tepam::procedure ::stc::apply {
-description "Sends a test configuration to the Spirent TestCenter chassis."
    -named_arguments_first 0
    -args {}
} {
    Log "INFO" "user.scripting" "stc::apply"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }
    
    set response [Execute "PUT" $serveraddress "/stcapi/apply" -headers [list "X-STC-API-Session" $sessionid "Content-Length" 0]]

    Log "INFO" "user.scripting" "return $response"

    return $response
}

#==============================================================================
tepam::procedure ::stc::connect {
-description "Establishes a connection with a Spirent TestCenter chassis."
    -named_arguments_first 0
    -args {
        {chassisaddress
            -description "An IP address or a DNS host name that identifies a Spirent TestCenter chassis."}
    }
} {
    Log "INFO" "user.scripting" "stc::connect $args"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }
    
    set response [Execute "PUT" $serveraddress "/stcapi/connections/$chassisaddress" -headers [list "X-STC-API-Session" $sessionid]]

    Log "INFO" "user.scripting" "return $response"

    return $response
}


#==============================================================================
tepam::procedure ::stc::disconnect {
-description "Removes a connection with a Spirent TestCenter chassis."
    -named_arguments_first 0
    -args {
        {chassisaddress
            -description "An IP address or a DNS host name that identifies a Spirent TestCenter chassis."}
    }
} {
    Log "INFO" "user.scripting" "stc::disconnect $args"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }
    
    set response [Execute "DELETE" $serveraddress "/stcapi/connections/$chassisaddress" -headers [list "X-STC-API-Session" $sessionid]]

    Log "INFO" "user.scripting" "return $response"

    return $response    
}

#==============================================================================
tepam::procedure ::stc::create {
-description "Creates one or more Spirent TestCenter Automation objects."
    -named_arguments_first 0
    -args {
        {objecttype
            -description "The object type."}
        {attributelist 
            -type        "string"
            -default     ""
            -multiple
        }
    }
} {
    Log "INFO" "user.scripting" "stc::create $args"

    set attributes "object_type=$objecttype"
    if { $attributelist ne "" } {
        append attributes "&" [FormatAttributesWithValues $attributelist]
    }

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    
    set jsonresponse [Execute "POST" $serveraddress "/stcapi/objects" -headers [list "X-STC-API-Session" $sessionid] -payload $attributes]

    set responsedict [::json::json2dict $jsonresponse]

    # The response will be the handle of the new object.
    set response [dict get $responsedict "handle"]    
    
    Log "INFO" "user.scripting" "return $response"

    return $response
}

#==============================================================================
tepam::procedure ::stc::delete {
-description "Deletes the specified object."
    -named_arguments_first 0
    -args {
        {object
            -description "The object handle that identifies the object to be deleted."}
    }
} {
    Log "INFO" "user.scripting" "stc::delete $args"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    set response [Execute "DELETE" $serveraddress "/stcapi/objects/$object" -headers [list "X-STC-API-Session" $sessionid]]

    # stc::delete doesn't actually return anything.
    Log "INFO" "user.scripting" "return $response"

    return $response
}

#==============================================================================
tepam::procedure ::stc::help {
-description "Displays help about the Spirent TestCenter Automation API and data model."
    -named_arguments_first 0
    -args {
        {subject 
            -type    "string"
            -default ""}
    }
} {
    Log "INFO" "user.scripting" "stc::help $args"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid ne "" } {
        set jsonresponse [Execute "GET" $serveraddress "/stcapi/help/$subject" -headers [list "X-STC-API-Session" $sessionid]]
    } else {
        set jsonresponse [Execute "GET" $serveraddress "/stcapi/help/$subject"]
    }

    set responsedict [::json::json2dict $jsonresponse]

    if { [dict exists $responsedict "message"] } {
        set response [dict get $responsedict "message"]
    } else {
        set response $responsedict
    }

    Log "INFO" "user.scripting" "return $response"

    return $response
}

#==============================================================================
tepam::procedure {::stc::help list} {
-description "Search feature that extends the help functionality to list and search 
              for config types and commands. When searching for commands, all 
              commands including the STAK commands that are available on the 
              system running Spirent TestCenter, are accessible."
    -named_arguments_first 0
    -args {
        {subject
            -choices     "configTypes commands"}
        {search
            -description "Item name with zero or more wildcard characters (*) 
                          that specifies names that must match the wildcard pattern."
            -default     ""}            
    }
} {
    Log "INFO" "user.scripting" "stc::help list $args"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    if { $search ne "" } {
        # Add the separator.
        set search "&$search"
    }

    set jsonresponse [Execute "GET" $serveraddress "/stcapi/help/list?${subject}${search}" -headers [list "X-STC-API-Session" $sessionid] -debug]

    set responsedict [::json::json2dict $jsonresponse]

    Log "INFO" "user.scripting" "return $responsedict"

    return $responsedict
}

#==============================================================================
tepam::procedure ::stc::log {
-description "Writes a diagnostic message to a log file or to standard output."
    -named_arguments_first 0
    -args {
        {loglevel
            -description "Identifies the severity of the message."}
        {message 
            -type        "string"
            -default     ""}
    }
} {
    Log "INFO" "user.scripting" "stc::log $args"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    set arguments "log_level=$loglevel&message=[::http::formatQuery $message]"
    
    set response [Execute "POST" $serveraddress "/stcapi/log/" -headers [list "X-STC-API-Session" $sessionid] -payload $arguments]

    # Actually, config doesn't actually have a response.
    Log "INFO" "user.scripting" "return $response"

    return $response    
}

#==============================================================================
tepam::procedure ::stc::perform {
-description "Executes a command."
    -named_arguments_first 0
    -args {
        {command
            -description "The command name."}
        {attributelist 
            -type        "string"
            -default     ""
            -multiple}
    }
} {
    Log "INFO" "user.scripting" "stc::perform $args"

    # There are a number of commands that deal with files, and they need
    # special treatment since we are dealing with a remote file system (Lab Server).

    # Automatically upload the file specified for any of the following commands.
    array set attributearray [string tolower $attributelist]
    switch -glob -- [string tolower $command] {        
        "queryresult*" -
        "loadfromdatabase*" { set attributename "-databaseconnectionstring" }
        "loadfromxml*" -                
        "downloadfile*" -
        "licensedownloadfile*" -
        "loadfilterfromlibrary*" -
        "ManualScheduleLoadFromTemplate*" { set attributename "-filename" }
        "pppuploadauthenticationfile*" { set attributename "-authenticationfilepath" }
    }

    if { [info exists attributename] } {
        # First, make sure the file exists, and then upload it to the Lab Server.
        set filename $attributearray($attributename)

        stc::fileUpload $filename    

        # Change the filename attribute so that only the filename remains (no path).
        set attributearray($attributename) [file tail $filename]

        # Modify the attribute list with the new filename.
        set attributelist [array get attributearray]
    }    
    catch {unset attributename}

    # Automatically download files generated by the following commands.
    # Before executing the command, strip off the path from the filename.
    switch -glob -- [string tolower $command] {        
        "saveresult" -
        "saveresultcommand" { set attributename "-databaseconnectionstring" }
        "saveresults*" { set attributename "-resultfilename" }
        "saveasxml*" -
        "savetotcc*" -
        "capturedatasave*" { set attributename "-filename" }
    }        

    if { [info exists attributename] } {
        # First, make sure the file exists, and then upload it to the Lab Server.
        set filename $attributearray($attributename)

        # Change the filename attribute so that only the filename remains (no path).
        set attributearray($attributename) [file tail $filename]

        # Modify the attribute list with the new filename.
        set attributelist [array get attributearray]
    }        
    catch {array unset attributearray}    

    set attributes "command=$command"
    if { $attributelist ne "" } {
        append attributes "&" [FormatAttributesWithValues $attributelist]
    }

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }
    
    set jsonresponse [Execute "POST" $serveraddress "/stcapi/perform/" -headers [list "X-STC-API-Session" $sessionid] -payload $attributes]

    set responsedict [::json::json2dict $jsonresponse]
    
    # Add the leading dash (-) to all attributes.
    set response ""
    dict for {key value} $responsedict {
        lappend response -$key $value
    }    

    # Automatically download files generated by the following commands:    
    switch -glob -- [string tolower $command] {        
        "saveresult" -
        "saveresultcommand" { set attributename "-databaseconnectionstring" }
        "saveresults*" { set attributename "-resultfilename" }
        "saveasxml*" -
        "savetotcc*" -
        "capturedatasave*" { set attributename "-filename" }        
    }    

    if { [info exists attributename] } {
        # We need to download the file. First order of business is to determine
        # the actual name of the file on the Lab Server. Spirent TestCenter puts
        # the files into wacky locations that are based on the loaded TCC filename 
        # ("Untitled" if there isn't one.)  
        set path [stc::get "system1.project" -ConfigurationFileName]
        set path [file tail $path]
        set path [file root $path]

        # The actual filename returned by the perform command may be different
        # from the user's filename (I'm thinking timestamps).
        # Extract the returned filename from the response.
        array set attributearray $response
        set actualfilename $attributearray($attributename)

        set targetfilename [file join $path [file tail $actualfilename]]

        # Make sure the local path exists.
        set localpath [file dirname $filename]
        catch {file mkdir $localpath}

        # Now download the file to the specified location.
        stc::fileDownload $targetfilename -dstpath $localpath
    }

    Log "INFO" "user.scripting" "return $response"
    
    return $response
}

#==============================================================================
tepam::procedure ::stc::release {
-description "Terminates the reservation of one or more port groups."
    -named_arguments_first 0
    -args {
        {portlist 
            -description "A chassis/slot/port tuple location list."
            -type        "string"
            -default     ""
            -multiple
        }
    }
} {
    # Since I consider this to be an aliased command, I'm not going to log it.
    stc::perform "ReleasePort" -Location $portlist

    return
}

#==============================================================================
tepam::procedure ::stc::reserve {
-description "Reserves one or more port groups."
    -named_arguments_first 0
    -args {
        {portlist 
            -description "A chassis/slot/port tuple location list."
            -type        "string"
            -default     ""
            -multiple
        }
    }
} {
    # Since I consider this to be an aliased command, I'm not going to log it.
    set response [stc::perform "ReservePort" -Location $portlist]

    return $response
}

#==============================================================================
tepam::procedure ::stc::sleep {
-description "Suspends Tcl application execution."
    -named_arguments_first 0
    -args {
        {seconds
            -description "The object handle."
            -type        integer}
    }
} {
    Log "INFO" "user.scripting" "stc::sleep $seconds"
    after [expr $seconds * 1000]
    return
}

#==============================================================================
tepam::procedure ::stc::subscribe {
-description "Enables real-time result collection."
    -named_arguments_first 0
    -args {
        {attributelist 
            -type        "string"
            -default     ""
            -multiple
        }
    }
} {
    # Since I consider this to be an aliased command, I'm not going to log it.
    set response [stc::perform "ResultsSubscribe" $attributelist]

    return $response
}

#==============================================================================
tepam::procedure ::stc::unsubscribe {
-description "Removes a previously established subscription."
    -named_arguments_first 0
    -args {
        {handle
            -description "The handle for the ResultDataSet object associated
                          with the subscription. (The handle is returned by 
                          the subscribe function.)"}
    }
} {
    # Since I consider this to be an aliased command, I'm not going to log it.
    set response [stc::perform "ResultDataSetUnsubscribe" -ResultDataSet $handle]

    return $response
}

#==============================================================================
tepam::procedure ::stc::waitUntilComplete {
-description "Blocks your application until the test has finished."
    -named_arguments_first 0
    -args {
        {-timeout
            -description "The number of seconds the function will block before 
                          returning, regardless of the state of the sequencer. 
                          This attribute is optional; if you do not specify 
                          -timeout, waitUntilComplete will block until the 
                          sequencer finishes."
            -default     ""}
    }
} {
    Log "INFO" "user.scripting" "stc::waitUnitComplete - Not yet implemented"
    error "::stc::waitUntilComplete is not yet implemented for the REST API Tcl client."
    return
}

#==============================================================================
tepam::procedure ::stc::fileUpload {
    -description "Upload the specified file to REST API server."
    -named_arguments_first 0
    -args {
        {filename
            -description "The name of the file to upload."}
    }
} {

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::fileUpload $filename"

    if { ! [file exists $filename] } {
        error "The file '$filename' does not exist."
    }
 
    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    # Construct the URL...    
    set url "http://${serveraddress}/stcapi/files/"
    set headers [list "X-STC-API-Session" $sessionid "content-disposition" "attachment\; filename=[file tail $filename]"]

    set fh [open $filename r]       

    set responsedict ""
    set errorhasoccurred [catch {
        
        set token [::http::geturl $url -headers      $headers \
                                       -querychannel $fh      \
                                       -type         "application/octet-stream"]

        # Examine the response.
        upvar #0 $token state 

        set responsedict [::json::json2dict $state(body)] 
        ::http::cleanup $token                                                                     
    } errmsg]
    
    close $fh                                                                 

    if { $errorhasoccurred } {
        Log "ERROR" "user.scripting.rest" $errmsg
        error $errmsg
    }        
    
    Log $loglevel "user.scripting.rest" "return $responsedict"

    return $responsedict
}

#==============================================================================
tepam::procedure ::stc::fileDownload {
    -description "Download the specified file to REST API server."
    -named_arguments_first 0
    -args {
        {filenamelist
            -description "The list of filenames to download. If the filenamelist is
                          not specified, all of the available files will be downloaded."
            -default     ""}
        {-dstpath
            -description "The path where the downloaded file will be stored. If
                          the directory does not exist, it will be created.
                          The current directory is the default."
            -default     ""}            
    }
} {

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::fileDownload $filenamelist -dstpath $dstpath"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    if { $filenamelist eq "" } {
        # The source file was not specified. Just grab all available files.
        set filenamelist [::stc::fileList]
    }    

    if { $dstpath ne "" && ! [file exists $dstpath] } {
        file mkdir $dstpath
    }

    set dstfilenamelist ""
    foreach filename $filenamelist {
        # Construct the URL...    
        set url "http://${serveraddress}/stcapi/files/$filename"
        
        set headers [list "X-STC-API-Session" $sessionid]

        # NOTE: Some source files may be in a subdirectory. Strip
        #       off subdirectory information from the dst filename 
        #       and save the file where the user asked to save it.
        set fullfilename [file join $dstpath [file tail $filename]]        

        ::http::config -accept "application/octet-stream"

        set fh [open $fullfilename w]

        set errorhasoccurred [catch {

            set token [::http::geturl $url -channel $fh -headers $headers]            
        } errmsg]

        # Examine the response.
        upvar #0 $token state 

        ::http::cleanup $token                                                                             

        close $fh
        ::http::config -accept "*/*"
        
        if { $errorhasoccurred } {
            # Delete the file that we just created, otherwise, it will
            # probably be an empty file.

            catch {file delete $fullfilename}
            error $errmsg
        } else {
            lappend dstfilenamelist $fullfilename
        }

    } ;# End foreach filename 

    Log $loglevel "user.scripting.rest" "return $dstfilenamelist"

    return $dstfilenamelist
}

#==============================================================================
tepam::procedure ::stc::fileList {
    -description "Returns a list of files on the REST API server."
    -named_arguments_first 0
    -args {}
} {

    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::fileList"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    # Construct the URL...    
    set url "http://${serveraddress}/stcapi/files/"
    set headers [list "X-STC-API-Session" $sessionid]

    set responsedict ""
    set errorhasoccurred [catch {
        
        set token [::http::geturl $url -headers $headers]

        # Examine the response.
        upvar #0 $token state 

        set responsedict [::json::json2dict $state(body)] 

        ::http::cleanup $token                                                                     
    } errmsg]
    
    if { $errorhasoccurred } {
        Log "ERROR" "user.scripting.rest" $errmsg
        error $errmsg
    }        
    
    Log $loglevel "user.scripting.rest" "return $responsedict"

    return $responsedict
}

#==============================================================================
tepam::procedure ::stc::getSystemInfo {
    -description "Get information about the Spirent TestCenter system. Returns
                  a dictionary."
    -named_arguments_first 0
    -args {}
} {
    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::getSystemInfo"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    set jsonresponse [Execute "GET" $serveraddress "/stcapi/system/" -headers [list "X-STC-API-Session" $sessionid]]

    set responsedict [::json::json2dict $jsonresponse]

    Log $loglevel "user.scripting.rest" "return $responsedict"

    return $responsedict
}

#==============================================================================
tepam::procedure ::stc::getChassisInfo {
    -description "Get information about the specified chassis."
    -named_arguments_first 0
    -args {
        {chassisaddress
            -description "An IP address or a DNS host name that identifies a Spirent TestCenter chassis."}
    }
} {
    # If this proc is called directly by the user, log it as "INFO", otherwise, "DEBUG".
    set loglevel "INFO"
    if { [info level] > 1 } {
        # This procedure was called by another procedure.
        set callingproc [lindex [info level -1] 0]
        if { [regexp $callingproc $::stc::state(procs)] } {
            set loglevel "DEBUG"
        }
    }    
    Log $loglevel "user.scripting.rest" "stc::getChassisInfo $chassisaddress"

    set session [::stc::getCurrentSession]           
    set serveraddress [dict get $session "fulladdress"]     
    set sessionid     [dict get $session "sessionid"]

    if { $sessionid eq "" } {
        error "STC REST Client API is not initialized."
    }

    set jsonresponse [Execute "GET" $serveraddress "/stcapi/chassis/$chassisaddress" -headers [list "X-STC-API-Session" $sessionid]]

    set responsedict [::json::json2dict $jsonresponse]

    Log $loglevel "user.scripting.rest" "return $responsedict"

    return $responsedict
}

###############################################################################
####
####    Private Procedures
####
###############################################################################
tepam::procedure ::stc::Execute {
    -description "Execute the specified HTTP verb (GET, PUT, POST, HEAD or DELETE) and
                  return the response from the server."
    -named_arguments_first 0
    -args {
        {verb 
            -description "The HTTP verb that will be executed."
            -choices     "GET PUT POST HEAD DELETE"}
        {serveraddress
            -description "The IP address of the Spirent REST API server."}
        {path
            -description "The STC API resource that the verb will operate on.
                          eg: /stcapi/objects/<objecthandle>"}
        {-headers
            -description "A key-value pair list of headers to include.
                          eg: X-STC-API-Session {Session1 - mjefferson}"
            -default     ""}
        {-payload
            -description "Payload data."
            -default     ""}
    }
} {

    # Construct the URL...    
    set url "http://${serveraddress}${path}"

    switch -- [string toupper $verb] {
        "GET"    {}
        "PUT"    { 
            append url " -method PUT"
            
            if { $payload ne "" } {
                append url " -query [list $payload]" 
            }
        }
        "HEAD"   { append url " -validate 1"     }
        "DELETE" { append url " -method DELETE"  }    
        "POST"   { 
            if { $payload ne "" } {
                append url " -query [list $payload]" 
            }            
        }            
        default {
            error "The HTTP verb $verb is not supported."
        }
    } ;# End switch

    if { $headers ne "" } {
        append url " -headers [list $headers]"   
    }        

    Log "DEBUG" "fmwk.bll.init" "Execute URL=$url"
    set cmd "::http::geturl $url"
    set token [eval $cmd]        

    # Examine the response.
    upvar #0 $token state  

    # Log the response.
    set logmsg ""
    foreach key [array names state] {
        append logmsg [format %-17s "$key:"] $state($key) \n
    }
    Log "DEBUG" "fmwk.bll.init" "Response State:\n$logmsg"  

    set response ""
    # Check for HTTP errors.
    if { $state(status) ne "ok" } {
        # An error has occurred: reset, timeout or error.
        Log "ERROR" "fmwk.bll.init" "There was a response error ($state(status))."
        error $state(status)
    } else {
        # Check for server errors.
        set code 0
        set msg  ""
        regexp {\S+ ([0-9]+) (.+)} $state(http) -> code msg

        if { $code < 200 || $code > 299 } {
            # An error has occurred.            
            if { $code == 500 && $state(body) ne "" } {
                set response [::json::json2dict $state(body)]

                set errmsg [dict get $response "message"]
                Log "ERROR" "fmwk.bll.init" $errmsg

                # This code makes it look like the calling procedure threw the
                # error. This mimicks what a Spirent TestCenter command looks like.
                return -code error -level 2 $errmsg
            } else {
                Log "ERROR" "fmwk.bll.init" "An unknown error occurred ($code): $msg"
                error "An unknown error occurred" $msg $code
            }

        } else {
            # The command execute without an error.
            set response $state(body)
        }
    }

    ::http::cleanup $token

    return $response
}

#==============================================================================
proc ::stc::NormalizeIPv4 { address } {
    # Normalize (strip of any leading zeros) from the specified IPv4 address.

    set normalizedaddress ""
    foreach octet [split $address .] {
        lappend normalizedaddress [format %d $octet]
    }
    set normalizedaddress [join $normalizedaddress .]

    return $normalizedaddress
}

#==============================================================================
proc ::stc::GetFullAddress { address } {
    # Returns the IP address and TCP port. If specified address does not 
    # include the TCP port and the session was not previously used by this process, 
    # the default port (80) will be added.
    # A dictionary, with the keys "address", "fulladdress" and "tcpport" will 
    # be returned.
    # address = 1.1.1.1
    # tcpport = 80
    # fulladdress = 1.1.1.1:80

    variable ::stc::sessions

    set serverip   [lindex [split $address ":"] 0]
    set serverport [lindex [split $address ":"] 1]

    set serverip [NormalizeIPv4 $serverip]

    dict set server "address" [NormalizeIPv4 $serverip]

    if { $serverport eq "" } {
        if { [info exists sessions] && [dict exists $sessions $serverip "tcpport"] } {
            set serverport [dict get $sessions $serverip "tcpport"]        
        } else {
            #set serverport 8888
            set serverport 80
        }
    }

    dict set server "tcpport"     $serverport
    dict set server "fulladdress" $serverip:$serverport

    return $server
}

#==============================================================================
proc ::stc::FormatAttributes { attributelist } {
    # Attributes need to be formatted for the REST API. Returns a dict with 
    # the keys "attributes" and "count".
    # eg:
    #   -this -that(2) -and.the.other 
    # ...becomes:
    #   this&that(2)&and.the.other

    set attributes ""
    set i          0
    foreach attribute $attributelist {
        # Remove the leading dash (-).
        regsub {^-} $attribute {} attribute

        if { $attributes eq "" } {
            append attributes $attribute
        } else {
            append attributes "&" $attribute
        }
        incr i
    }
    dict set attributedict "attributes" $attributes
    dict set attributedict "count"      $i

    return $attributedict
}

#==============================================================================
proc ::stc::FormatAttributesWithValues { attributevaluelist } {
    # Attributes need to be formatted for the REST API.
    # eg:
    #   -this 1 -that(2) 2 -and.the.other {3 4 5} 
    # ...becomes:
    #   this=1&that(2)=2&and.the.other=1%202%203
    
    set attributes ""
    foreach {attribute value} $attributevaluelist {
        # Remove the leading dash (-).
        regsub {^-} $attribute {} attribute

        # We might also have to format the attribute as well.
        set value [::http::formatQuery $value]

        if { $attributes eq "" } {
            append attributes $attribute=$value
        } else {
            append attributes "&" $attribute=$value
        }
    }
    return $attributes
}

#==============================================================================
proc ::stc::InitLogging { loglevel } {
    # Initialize the logging.
    # All log files are saved in ~/Spirent/TestCenterREST/Logs/<YYY-MM-DD-HH-MM-SS_PIDXXXX>,
    # unless the environment variable STC_LOG_OUTPUT_DIRECTORY is specified.    

    # Construct the log path.            
    # It should look something like this:
    #~/Spirent/TestCenterREST/Logs/2016-01-05_12-39-46_PID20664    

    if { [info exists ::env(STC_LOG_OUTPUT_DIRECTORY)] } {
        set logpath $::env(STC_LOG_OUTPUT_DIRECTORY)
    } else {
        # This is the default location for log files.
        set logpath "~/Spirent/TestCenterREST/Logs/"        
        set tempdir "[clock format [clock seconds] -format "%Y-%m-%d_%H-%M-%S"]_PID$::stc::state(pid)"        
        set logpath [file join $logpath $tempdir]        
    }

    if { [catch {file mkdir $logpath} errmsg] } {
        Log "WARN" "Unable to create the log directory '$logpath' due to the following:\n$errmsg"
        set logpath $::state(pwd)
    }

    set filename [file join $logpath "restclient.bll.log"]

    # Create a blank log. Overwrite any existing log file.
    set fh [open $filename w]
    close $fh

    set ::stc::state(loglevel) $loglevel
    set ::stc::state(logfile)  $filename

    # Add some initial log information.
    if { [string match -nocase $::tcl_platform(platform) "windows"] } {
        # Host Name:                 WIN-CM0LSBAKT56
        # OS Name:                   Microsoft Windows 7 Enterprise
        # OS Version:                6.1.7600 N/A Build 7600
        # OS Manufacturer:           Microsoft Corporation
        # OS Configuration:          Standalone Workstation
        # OS Build Type:             Multiprocessor Free

        set systeminfo [exec systeminfo]
        regexp -linestop {OS Name:\s+(.+)}    $systeminfo -> osname
        regexp -linestop {OS Version:\s+(.+)} $systeminfo -> osversion
        set osinfo "$osname ($osversion)"

        #regexp -linestop {Total Physical Memory:\s+(.+)} $systeminfo -> memory        
    } else {
        set osinfo [exec uname -a]
    }

    
    Log "INFO" "fmwk.bll.init" "Operating System: $osinfo"
    #Log "INFO" "fmwk.bll.init" "Physical Memory: $memory"
    Log "INFO" "fmwk.bll.init" "Tcl REST API: $::stc::fullversion"
    Log "INFO" "fmwk.bll.init" "Application installation directory : $::stc::filepath"
    Log "INFO" "fmwk.bll.init" "Application session data directory : $logpath"

    return
}


#==============================================================================
proc ::stc::Log { level module msg } {

    # Convert the cutoff for log messages (state(loglevel)) into an index.
    switch -- [string toupper $::stc::state(loglevel)] {
        "ERROR" { set levelindex 0 }
        "WARN"  { set levelindex 1 }
        "INFO"  { set levelindex 2 }
        "DEBUG" { set levelindex 3 }
        default {
            error "The log level '$::stc::state(loglevel)' is not valid."
        }
    }

    # Determine if the message needs to be logged.
    if { [lsearch -exact {ERROR WARN INFO DEBUG} $level] <= $levelindex } {

        set timestamp [clock format [clock seconds] -format "%y/%m/%d %H:%M:%S"]
        set msg "$timestamp [format %-5s $level] $::stc::state(pid) - [format %-20s $module] - $msg"

        set fh [open $::stc::state(logfile) a]
        puts $fh $msg
        close $fh

        if { $::stc::state(verbose) } {
            puts $msg
        }
    }

    return
}

###############################################################################
####
####    Main
####
###############################################################################





#set log [logger::init main]


















