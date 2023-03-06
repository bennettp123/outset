//
//  Functions.swift
//  outset
//
//  Created by Bart Reardon on 1/12/2022.
//

import Foundation
import SystemConfiguration
import OSLog

struct OutsetPreferences: Codable {
    var wait_for_network : Bool = false
    var network_timeout : Int = 180
    var ignored_users : [String] = []
    var override_login_once : [String:Date] = [String:Date]()
}

struct FileHashes: Codable {
    var sha256sum : [String:String] = [String:String]()
}

func ensure_root(_ reason : String) {
    if !isRoot() {
        writeLog("Must be root to \(reason)", logLevel: .error)
        exit(1)
    }
}

func isRoot() -> Bool {
    return NSUserName() == "root"
}

func getValueForKey(_ key: String, inArray array: [String: String]) -> String? {
    // short function that treats a [String: String] as a key value pair.
    return array[key]
}

func writeLog(_ message: String, logLevel: OSLogType = .info, log: OSLog = osLog) {
    let logMessage = "\(message)"
    
    os_log("%{public}@", log: log, type: logLevel, logMessage)
    if logLevel == .error || logLevel == .info || (debugMode && logLevel == .debug) {
        // print info, errors and debug to stdout
        print("\(oslogTypeToString(logLevel).uppercased()): \(message)")
    }
    writeFileLog(message: message, logLevel: logLevel)
}

func writeFileLog(message: String, logLevel: OSLogType) {
    if logLevel == .debug && !debugMode {
        return
    }
    let logFileURL = URL(fileURLWithPath: logFile)
    if !checkFileExists(path: logFile) {
        FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        let attributes = [FileAttributeKey.posixPermissions: 0o666]
        do {
            try FileManager.default.setAttributes(attributes, ofItemAtPath: logFileURL.path)
        } catch {
            print("\(oslogTypeToString(.error).uppercased()): Unable to create log file at \(logFile)")
            return
        }
    }
    do {
        let fileHandle = try FileHandle(forWritingTo: logFileURL)
        defer { fileHandle.closeFile() }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let date = dateFormatter.string(from: Date())
        let logEntry = "\(date) \(oslogTypeToString(logLevel).uppercased()): \(message)\n"

        fileHandle.seekToEndOfFile()
        fileHandle.write(logEntry.data(using: .utf8)!)
    } catch {
        print("\(oslogTypeToString(.error).uppercased()): Unable to read log file at \(logFile)")
        return
    }
}

func oslogTypeToString(_ type: OSLogType) -> String {
    switch type {
        case OSLogType.default: return "default"
        case OSLogType.info: return "info"
        case OSLogType.debug: return "debug"
        case OSLogType.error: return "error"
        case OSLogType.fault: return "fault"
        default: return "unknown"
    }
}

func getConsoleUserInfo() -> (username: String, userID: String) {
    // We need the console user, not the process owner so NSUserName() won't work for our needs when outset runs as root
    let consoleUserName = runShellCommand("who | grep 'console' | awk '{print $1}'").output
    let consoleUserID = runShellCommand("id -u \(consoleUserName)").output
    return (consoleUserName.trimmingCharacters(in: .whitespacesAndNewlines), consoleUserID.trimmingCharacters(in: .whitespacesAndNewlines))
}

func writePreferences(prefs: OutsetPreferences) {
    
    if debugMode {
        showPrefrencePath("Stor")
    }
    
    let defaults = UserDefaults.standard
        
    // Take the OutsetPreferences object and write it to UserDefaults
    let mirror = Mirror(reflecting: prefs)
    for child in mirror.children {
        // Use the name of each property as the key, and save its value to UserDefaults
        if let propertyName = child.label {
            defaults.set(child.value, forKey: propertyName)
        }
    }
}

func loadPreferences() -> OutsetPreferences {
    
    if debugMode {
        showPrefrencePath("Load")
    }
    
    let defaults = UserDefaults.standard
    var outsetPrefs = OutsetPreferences()
    
    outsetPrefs.network_timeout = defaults.integer(forKey: "network_timeout")
    outsetPrefs.ignored_users = defaults.array(forKey: "ignored_users") as? [String] ?? []
    outsetPrefs.override_login_once = defaults.object(forKey: "override_login_once") as? [String:Date] ?? [:]
    outsetPrefs.wait_for_network = defaults.bool(forKey: "wait_for_network")
    
    return outsetPrefs
}

func loadRunOnce() -> [String:Date] {
    
    if debugMode {
        showPrefrencePath("Load")
    }
    
    let defaults = UserDefaults.standard
    var runOnceKey = "run_once"
    
    if isRoot() {
        runOnceKey = runOnceKey+"-"+getConsoleUserInfo().username
    }
    return defaults.object(forKey: runOnceKey) as? [String:Date] ?? [:]
}

func writeRunOnce(runOnceData: [String:Date]) {
    
    if debugMode {
        showPrefrencePath("Stor")
    }
    
    let defaults = UserDefaults.standard
    var runOnceKey = "run_once"
    
    if isRoot() {
        runOnceKey = runOnceKey+"-"+getConsoleUserInfo().username
    }
    defaults.set(runOnceData, forKey: runOnceKey)
}

func showPrefrencePath(_ action: String) {
    let path = NSSearchPathForDirectoriesInDomains(.libraryDirectory, .userDomainMask, true)
    let prefsPath = path[0].appending("/Preferences").appending("/\(Bundle.main.bundleIdentifier!).plist")
    writeLog("\(action)ing preference file: \(prefsPath)", logLevel: .debug)
}

func shasumLoadApprovedFileHashList() -> [String:String] {
    // imports the list of file hashes that are approved to run
    var outset_file_hash_list = FileHashes()
    
    let defaults = UserDefaults.standard
    let hashes = defaults.object(forKey: "sha256sum")

    if let data = hashes as? [String: String] {
        for (key, value) in data {
            outset_file_hash_list.sha256sum[key] = value
        }
    }

    return outset_file_hash_list.sha256sum
}

func isNetworkUp() -> Bool {
    // https://stackoverflow.com/a/39782859/17584669
    // perform a check to see if the network is available.
    
    var zeroAddress = sockaddr_in(sin_len: 0, sin_family: 0, sin_port: 0, sin_addr: in_addr(s_addr: 0), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
    zeroAddress.sin_len = UInt8(MemoryLayout.size(ofValue: zeroAddress))
    zeroAddress.sin_family = sa_family_t(AF_INET)

    let defaultRouteReachability = withUnsafePointer(to: &zeroAddress) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {zeroSockAddress in
            SCNetworkReachabilityCreateWithAddress(nil, zeroSockAddress)
        }
    }

    var flags: SCNetworkReachabilityFlags = SCNetworkReachabilityFlags(rawValue: 0)
    if SCNetworkReachabilityGetFlags(defaultRouteReachability!, &flags) == false {
        return false
    }

    let isReachable = (flags.rawValue & UInt32(kSCNetworkFlagsReachable)) != 0
    let needsConnection = (flags.rawValue & UInt32(kSCNetworkFlagsConnectionRequired)) != 0
    let ret = (isReachable && !needsConnection)

    return ret
}

func waitForNetworkUp(timeout: Double) -> Bool {
    // used during --boot if "wait_for_network" prefrence is true
    var networkUp = false
    let deadline = DispatchTime.now() + timeout
    while !networkUp && DispatchTime.now() < deadline {
        writeLog("Waiting for network: \(timeout) seconds", logLevel: .debug)
        networkUp = isNetworkUp()
        if !networkUp {
            writeLog("Waiting...", logLevel: .debug)
            Thread.sleep(forTimeInterval: 1)
        }
    }
    if !networkUp && DispatchTime.now() > deadline {
        writeLog("No network connectivity detected after \(timeout) seconds", logLevel: .error)
    }
    return networkUp
}

func loginWindowDisable() {
    // Disables the loginwindow process
    writeLog("Disabling loginwindow process", logLevel: .debug)
    let cmd = "/bin/launchctl unload /System/Library/LaunchDaemons/com.apple.loginwindow.plist"
    _ = runShellCommand(cmd)
}

func loginWindowEnable() {
    // Enables the loginwindow process
    writeLog("Enabling loginwindow process", logLevel: .debug)
    let cmd = "/bin/launchctl load /System/Library/LaunchDaemons/com.apple.loginwindow.plist"
    _ = runShellCommand(cmd)
}

func getDeviceHardwareModel() -> String {
    // Returns the current devices hardware model from sysctl
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}

func getDeviceSerialNumber() -> String {
    // Returns the current devices serial number
    // TODO: fix warning 'kIOMasterPortDefault' was deprecated in macOS 12.0: renamed to 'kIOMainPortDefault'
    let platformExpert = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice") )
      guard platformExpert > 0 else {
        return "Serial Unknown"
      }
      guard let serialNumber = (IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0).takeUnretainedValue() as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) else {
        return "Serial Unknown"
      }
      IOObjectRelease(platformExpert)
      return serialNumber
}

func getOSBuildVersion() -> String {
    // Returns the current OS build from sysctl
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var osversion = [CChar](repeating: 0, count: size)
    sysctlbyname("kern.osversion", &osversion, &size, nil, 0)
    return String(cString: osversion)

}

func getOSVersion() -> String {
    // Returns the OS version
    let osVersion = ProcessInfo().operatingSystemVersion
    let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    return version
}

func writeSysReport() {
    // Logs system information to log file
    writeLog("User: \(getConsoleUserInfo())", logLevel: .debug)
    writeLog("Model: \(getDeviceHardwareModel())", logLevel: .debug)
    writeLog("Serial: \(getDeviceSerialNumber())", logLevel: .debug)
    writeLog("OS: \(getOSVersion())", logLevel: .debug)
    writeLog("Build: \(getOSBuildVersion())", logLevel: .debug)
}