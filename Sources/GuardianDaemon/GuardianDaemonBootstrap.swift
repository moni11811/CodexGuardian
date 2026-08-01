import Darwin
import Foundation

@_silgen_name("launch_activate_socket")
private func guardianLaunchActivateSocket(
    _ name: UnsafePointer<CChar>,
    _ descriptors: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>,
    _ count: UnsafeMutablePointer<Int>
) -> Int32

enum GuardianDaemonBootstrap {
    static func launchdSocket(named name: String) throws -> Int32 {
        var descriptors: UnsafeMutablePointer<Int32>?
        var count = 0
        let result = name.withCString {
            guardianLaunchActivateSocket($0, &descriptors, &count)
        }
        guard result == 0, let descriptors, count == 1 else {
            if let descriptors { free(descriptors) }
            throw GuardianDaemonServerError.noLaunchdSocket(result)
        }
        let descriptor = descriptors[0]
        free(descriptors)
        return descriptor
    }

    static func developmentSocket(path: String) throws -> Int32 {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard !path.isEmpty, path.utf8CString.count <= capacity else {
            throw GuardianDaemonServerError.invalidConfiguration
        }
        try prepareSocketPath(path)
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw GuardianDaemonServerError.systemCall("socket", errno)
        }
        do {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = path.utf8CString
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            _ = path.withCString { source in
                withUnsafeMutablePointer(to: &address.sun_path.0) { destination in
                    strlcpy(destination, source, pathCapacity)
                }
            }
            let length = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
            address.sun_len = UInt8(length)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard bindResult == 0 else {
                throw GuardianDaemonServerError.systemCall("bind", errno)
            }
            guard chmod(path, 0o600) == 0 else {
                throw GuardianDaemonServerError.systemCall("chmod", errno)
            }
            guard Darwin.listen(descriptor, 16) == 0 else {
                throw GuardianDaemonServerError.systemCall("listen", errno)
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func prepareSocketPath(_ path: String) throws {
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else {
                throw GuardianDaemonServerError.invalidConfiguration
            }
            guard unlink(path) == 0 else {
                throw GuardianDaemonServerError.systemCall("unlink", errno)
            }
        } else if errno != ENOENT {
            throw GuardianDaemonServerError.systemCall("lstat", errno)
        }
    }
}
