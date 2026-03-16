import Darwin

private let mountExecutable = "/sbin/mount"
private let filesystemType = "passthrough"

@inline(__always)
private func printError(_ message: String) {
    message.withCString { ptr in
        fputs(ptr, stderr)
        fputc(10, stderr)
    }
}

@inline(__always)
private func fail(_ message: String, exitCode: Int32 = 64) -> Never {
    printError("mount_spiderweb: \(message)")
    Darwin.exit(exitCode)
}

private func appendMountOptionArgument(_ option: String, from arguments: [String], index: inout Int, into passthrough: inout [String]) {
    passthrough.append(option)
    switch option {
    case "-o", "-u", "-g", "-m":
        index += 1
        guard index < arguments.count else {
            fail("missing value for \(option)")
        }
        passthrough.append(arguments[index])
    default:
        break
    }
}

private func parseInvocation(_ arguments: [String]) -> (passthrough: [String], resourcePath: String, mountpoint: String) {
    if arguments.count == 4, arguments[1] == "--direct" {
        return ([], arguments[2], arguments[3])
    }

    var passthrough: [String] = []
    var positional: [String] = []
    var index = 1
    while index < arguments.count {
        let argument = arguments[index]
        if argument == "--" {
            if index + 1 < arguments.count {
                positional.append(contentsOf: arguments[(index + 1)...])
            }
            break
        }
        if argument.hasPrefix("-") {
            appendMountOptionArgument(argument, from: arguments, index: &index, into: &passthrough)
        } else {
            positional.append(argument)
        }
        index += 1
    }

    guard positional.count >= 2 else {
        fail("expected resource path and mountpoint")
    }
    let mountpoint = positional[positional.count - 1]
    let resourcePath = positional[positional.count - 2]
    return (passthrough, resourcePath, mountpoint)
}

private func execMount(passthrough: [String], resourcePath: String, mountpoint: String) -> Never {
    var argvStrings = [mountExecutable, "-F", "-t", filesystemType]
    argvStrings.append(contentsOf: passthrough)
    argvStrings.append(resourcePath)
    argvStrings.append(mountpoint)

    var argv = argvStrings.map { strdup($0) }
    defer {
        for value in argv {
            if let value {
                free(value)
            }
        }
    }
    argv.append(nil)

    execv(mountExecutable, &argv)
    let errorCode = errno
    fail("failed to exec \(mountExecutable): \(String(cString: strerror(errorCode)))", exitCode: errorCode == 0 ? 72 : errorCode)
}

let parsed = parseInvocation(CommandLine.arguments)
execMount(passthrough: parsed.passthrough, resourcePath: parsed.resourcePath, mountpoint: parsed.mountpoint)
