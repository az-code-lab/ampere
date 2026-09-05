import Foundation
import Darwin

/// A root-owned executable is still replaceable if an ordinary user can
/// rename it, or one of its ancestor directories. Check the entire path,
/// rejecting symlinks and ACL write grants as well as POSIX write bits.
public enum HelperSecurity {
    public static func isProtected(path: String, directory: Bool = false) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var current = URL(fileURLWithPath: path).standardizedFileURL.path
        var expectsDirectory = directory
        while true {
            var info = stat()
            guard lstat(current, &info) == 0,
                  info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == (expectsDirectory ? S_IFDIR : S_IFREG),
                  !hasWriteACL(path: current) else { return false }
            if current == "/" { return true }
            current = (current as NSString).deletingLastPathComponent
            expectsDirectory = true
        }
    }

    /// Missing is allowed only for the leaf: its already-protected parent
    /// guarantees that an ordinary process cannot race directory creation.
    public static func canInstall(in directory: String) -> Bool {
        var info = stat()
        if lstat(directory, &info) == 0 {
            return isProtected(path: directory, directory: true)
        }
        guard errno == ENOENT else { return false }
        return isProtected(path: (directory as NSString).deletingLastPathComponent,
                           directory: true)
    }

    /// Pin each directory while retiring the old installation, whose parent
    /// may be user-writable. Never let a swapped directory symlink redirect
    /// root's unlink to another location. The leaf itself may be a symlink:
    /// unlinkat removes that link, without following it.
    public static func removeFileWithoutFollowingDirectories(at path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/").map(String.init)
        guard let name = components.last,
              !components.contains("."), !components.contains("..") else { return false }
        var parent = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { return false }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return errno == ENOENT }
            close(parent)
            parent = next
        }
        return unlinkat(parent, name, 0) == 0 || errno == ENOENT
    }

    static func hasWriteACL(path: String) -> Bool {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
            // Darwin also uses ENOENT when an existing file has no ACL.
            // Recheck existence to distinguish that from a missing path.
            if errno == ENOENT {
                var info = stat()
                return lstat(path, &info) != 0
            }
            // Filesystems without extended ACLs rely on the POSIX checks.
            return errno != ENOTSUP && errno != EOPNOTSUPP
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var selector = ACL_FIRST_ENTRY
        let writes: [acl_perm_t] = [ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_DELETE,
            ACL_DELETE_CHILD, ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES,
            ACL_WRITE_SECURITY, ACL_CHANGE_OWNER]
        while acl_get_entry(acl, Int32(selector.rawValue), &entry) == 0 {
            selector = ACL_NEXT_ENTRY
            var tag = ACL_UNDEFINED_TAG
            guard let entry, acl_get_tag_type(entry, &tag) == 0 else { return true }
            guard tag == ACL_EXTENDED_ALLOW else { continue }
            var permissions: acl_permset_t?
            guard acl_get_permset(entry, &permissions) == 0, let permissions else { return true }
            if writes.contains(where: { acl_get_perm_np(permissions, $0) != 0 }) { return true }
        }
        // Darwin reports the end of an ACL as EINVAL. Other retrieval
        // errors must not turn an unreadable ACL into a trusted path.
        return errno != EINVAL
    }
}
