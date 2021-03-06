//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
//  This file contains code that ensures errno is captured correctly when doing syscalls and no ARC traffic can happen inbetween that *could* change the errno
//  value before we were able to read it.
//  Its important that all static methods are declared with `@inline(never)` so its not possible any ARC traffic happens while we need to read errno.
//
//  Created by Norman Maurer on 11/10/17.
//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
@_exported import Darwin.C
import CNIODarwin
internal typealias MMsgHdr = CNIODarwin_mmsghdr
#elseif os(Linux) || os(FreeBSD) || os(Android)
@_exported import Glibc
import CNIOLinux
internal typealias MMsgHdr = CNIOLinux_mmsghdr
#else
let badOS = { fatalError("unsupported OS") }()
#endif

// Declare aliases to share more code and not need to repeat #if #else blocks
private let sysClose = close
private let sysShutdown = shutdown
private let sysBind = bind
private let sysFcntl: (CInt, CInt, CInt) -> CInt = fcntl
private let sysSocket = socket
private let sysSetsockopt = setsockopt
private let sysGetsockopt = getsockopt
private let sysListen = listen
private let sysAccept = accept
private let sysConnect = connect
private let sysOpen: (UnsafePointer<CChar>, CInt) -> CInt = open
private let sysOpenWithMode: (UnsafePointer<CChar>, CInt, mode_t) -> CInt = open
private let sysWrite = write
private let sysWritev = writev
private let sysRead = read
private let sysLseek = lseek
private let sysRecvFrom = recvfrom
private let sysSendTo = sendto
private let sysDup = dup
private let sysGetpeername = getpeername
private let sysGetsockname = getsockname
private let sysGetifaddrs = getifaddrs
private let sysFreeifaddrs = freeifaddrs
private let sysAF_INET = AF_INET
private let sysAF_INET6 = AF_INET6
private let sysAF_UNIX = AF_UNIX
private let sysInet_ntop = inet_ntop

#if os(Linux)
private let sysSendMmsg = CNIOLinux_sendmmsg
private let sysRecvMmsg = CNIOLinux_recvmmsg
#else
private let sysKevent = kevent
private let sysSendMmsg = CNIODarwin_sendmmsg
private let sysRecvMmsg = CNIODarwin_recvmmsg
#endif

private func isBlacklistedErrno(_ code: Int32) -> Bool {
    switch code {
    case EFAULT, EBADF:
        return true
    default:
        return false
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapSyscallMayBlock<T: FixedWidthInteger>(where function: StaticString = #function, _ body: () throws -> T) throws -> IOResult<T> {
    while true {
        let res = try body()
        if res == -1 {
            let err = errno
            switch err {
            case EINTR:
                continue
            case EWOULDBLOCK:
                return .wouldBlock(0)
            default:
                assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
                throw IOError(errnoCode: err, function: function)
            }

        }
        return .processed(res)
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapSyscall<T: FixedWidthInteger>(where function: StaticString = #function, _ body: () throws -> T) throws -> T {
    while true {
        let res = try body()
        if res == -1 {
            let err = errno
            if err == EINTR {
                continue
            }
            assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
            throw IOError(errnoCode: err, function: function)
        }
        return res
    }
}

/* Sorry, we really try hard to not use underscored attributes. In this case however we seem to break the inlining threshold which makes a system call take twice the time, ie. we need this exception. */
@inline(__always)
internal func wrapErrorIsNullReturnCall(where function: StaticString = #function, _ body: () throws -> UnsafePointer<CChar>?) throws -> UnsafePointer<CChar>? {
    while true {
        let res = try body()
        if res == nil {
            let err = errno
            if err == EINTR {
                continue
            }
            assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
            throw IOError(errnoCode: err, function: function)
        }
        return res
    }
}

enum Shutdown {
    case RD
    case WR
    case RDWR

    fileprivate var cValue: CInt {
        switch self {
        case .RD:
            return CInt(SHUT_RD)
        case .WR:
            return CInt(SHUT_WR)
        case .RDWR:
            return CInt(SHUT_RDWR)
        }
    }
}

internal enum Posix {
#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
    static let SOCK_STREAM: CInt = CInt(Darwin.SOCK_STREAM)
    static let SOCK_DGRAM: CInt = CInt(Darwin.SOCK_DGRAM)
    static let UIO_MAXIOV: Int = 1024
#elseif os(Linux) || os(FreeBSD) || os(Android)
    static let SOCK_STREAM: CInt = CInt(Glibc.SOCK_STREAM.rawValue)
    static let SOCK_DGRAM: CInt = CInt(Glibc.SOCK_DGRAM.rawValue)
    static let UIO_MAXIOV: Int = Int(Glibc.UIO_MAXIOV)
#else
    static var SOCK_STREAM: CInt {
        fatalError("unsupported OS")
    }
    static var SOCK_DGRAM: CInt {
        fatalError("unsupported OS")
    }
    static var UIO_MAXIOV: Int {
        fatalError("unsupported OS")
    }
#endif

    static let AF_INET = sa_family_t(sysAF_INET)
    static let AF_INET6 = sa_family_t(sysAF_INET6)
    static let AF_UNIX = sa_family_t(sysAF_UNIX)

    @inline(never)
    public static func shutdown(descriptor: CInt, how: Shutdown) throws {
        _ = try wrapSyscall {
            sysShutdown(descriptor, how.cValue)
        }
    }

    @inline(never)
    public static func close(descriptor: CInt) throws {
        let res = sysClose(descriptor)
        if res == -1 {
            let err = errno

            // There is really nothing "sane" we can do when EINTR was reported on close.
            // So just ignore it and "assume" everything is fine == we closed the file descriptor.
            //
            // For more details see:
            //     - https://bugs.chromium.org/p/chromium/issues/detail?id=269623
            //     - https://lwn.net/Articles/576478/
            if err != EINTR {
                assert(!isBlacklistedErrno(err), "blacklisted errno \(err) \(strerror(err)!)")
                throw IOError(errnoCode: err, function: "close")
            }
        }
    }

    @inline(never)
    public static func bind(descriptor: CInt, ptr: UnsafePointer<sockaddr>, bytes: Int) throws {
         _ = try wrapSyscall {
            sysBind(descriptor, ptr, socklen_t(bytes))
        }
    }

    @inline(never)
    // TODO: Allow varargs
    public static func fcntl(descriptor: CInt, command: CInt, value: CInt) throws {
        _ = try wrapSyscall {
            sysFcntl(descriptor, command, value)
        }
    }

    @inline(never)
    public static func socket(domain: CInt, type: CInt, `protocol`: CInt) throws -> CInt {
        return try wrapSyscall {
            let fd = sysSocket(domain, type, `protocol`)

            #if os(Linux)
                /* no SO_NOSIGPIPE on Linux :( */
                _ = unsafeBitCast(Glibc.signal(SIGPIPE, SIG_IGN) as sighandler_t?, to: Int.self)
            #else
                if fd != -1 {
                    _ = try? Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                }
            #endif
            return fd
        }
    }

    @inline(never)
    public static func setsockopt(socket: CInt, level: CInt, optionName: CInt,
                                  optionValue: UnsafeRawPointer, optionLen: socklen_t) throws {
        _ = try wrapSyscall {
            sysSetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }

    @inline(never)
    public static func getsockopt(socket: CInt, level: CInt, optionName: CInt,
                                  optionValue: UnsafeMutableRawPointer, optionLen: UnsafeMutablePointer<socklen_t>) throws {
         _ = try wrapSyscall {
            sysGetsockopt(socket, level, optionName, optionValue, optionLen)
        }
    }

    @inline(never)
    public static func listen(descriptor: CInt, backlog: CInt) throws {
        _ = try wrapSyscall {
            sysListen(descriptor, backlog)
        }
    }

    @inline(never)
    public static func accept(descriptor: CInt, addr: UnsafeMutablePointer<sockaddr>, len: UnsafeMutablePointer<socklen_t>) throws -> CInt? {
        let result: IOResult<CInt> = try wrapSyscallMayBlock {
            let fd = sysAccept(descriptor, addr, len)

            #if !os(Linux)
                if fd != -1 {
                    // TODO: Handle return code ?
                    _ = try? Posix.fcntl(descriptor: fd, command: F_SETNOSIGPIPE, value: 1)
                }
            #endif
            return fd
        }

        if case .processed(let fd) = result {
            return fd
        } else {
            return nil
        }
    }

    @inline(never)
    public static func connect(descriptor: CInt, addr: UnsafePointer<sockaddr>, size: socklen_t) throws -> Bool {
        do {
            _ = try wrapSyscall {
                sysConnect(descriptor, addr, size)
            }
            return true
        } catch let err as IOError {
            if err.errnoCode == EINPROGRESS {
                return false
            }
            throw err
        }
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt, mode: mode_t) throws -> CInt {
        return try wrapSyscall {
            sysOpenWithMode(file, oFlag, mode)
        }
    }

    @inline(never)
    public static func open(file: UnsafePointer<CChar>, oFlag: CInt) throws -> CInt {
        return try wrapSyscall {
            sysOpen(file, oFlag)
        }
    }

    @inline(never)
    public static func write(descriptor: CInt, pointer: UnsafePointer<UInt8>, size: Int) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            sysWrite(descriptor, pointer, size)
        }
    }

    @inline(never)
    public static func writev(descriptor: CInt, iovecs: UnsafeBufferPointer<IOVector>) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            sysWritev(descriptor, iovecs.baseAddress!, CInt(iovecs.count))
        }
    }

    @inline(never)
    public static func sendto(descriptor: CInt, pointer: UnsafePointer<UInt8>, size: size_t,
                              destinationPtr: UnsafePointer<sockaddr>, destinationSize: socklen_t) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            sysSendTo(descriptor, pointer, size, 0, destinationPtr, destinationSize)
        }
    }

    @inline(never)
    public static func read(descriptor: CInt, pointer: UnsafeMutablePointer<UInt8>, size: size_t) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            sysRead(descriptor, pointer, size)
        }
    }

    @inline(never)
    public static func recvfrom(descriptor: CInt, pointer: UnsafeMutablePointer<UInt8>, len: size_t, addr: UnsafeMutablePointer<sockaddr>, addrlen: UnsafeMutablePointer<socklen_t>) throws -> IOResult<ssize_t> {
        return try wrapSyscallMayBlock {
            sysRecvFrom(descriptor, pointer, len, 0, addr, addrlen)
        }
    }

    @discardableResult
    @inline(never)
    public static func lseek(descriptor: CInt, offset: off_t, whence: CInt) throws -> off_t {
        return try wrapSyscall {
            sysLseek(descriptor, offset, whence)
        }
    }

    @discardableResult
    @inline(never)
    public static func dup(descriptor: CInt) throws -> CInt {
        return try wrapSyscall {
            sysDup(descriptor)
        }
    }

    @discardableResult
    @inline(never)
    public static func inet_ntop(addressFamily: CInt, addressBytes: UnsafeRawPointer, addressDescription: UnsafeMutablePointer<CChar>, addressDescriptionLength: socklen_t) throws -> UnsafePointer<CChar>? {
        return try wrapErrorIsNullReturnCall {
            sysInet_ntop(addressFamily, addressBytes, addressDescription, addressDescriptionLength)
        }
    }

    // Its not really posix but exists on Linux and MacOS / BSD so just put it here for now to keep it simple
    @inline(never)
    public static func sendfile(descriptor: CInt, fd: CInt, offset: off_t, count: size_t) throws -> IOResult<Int> {
        var written: off_t = 0
        do {
            _ = try wrapSyscall { () -> ssize_t in
                #if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
                    var w: off_t = off_t(count)
                    let result: CInt = Darwin.sendfile(fd, descriptor, offset, &w, nil, 0)
                    written = w
                    return ssize_t(result)
                #elseif os(Linux) || os(FreeBSD) || os(Android)
                    var off: off_t = offset
                    let result: ssize_t = Glibc.sendfile(descriptor, fd, &off, count)
                    if result >= 0 {
                        written = result
                    } else {
                        written = 0
                    }
                    return result
                #else
                    fatalError("unsupported OS")
                #endif
            }
            return .processed(Int(written))
        } catch let err as IOError {
            if err.errnoCode == EAGAIN {
                return .wouldBlock(Int(written))
            }
            throw err
        }
    }

    @inline(never)
    public static func sendmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            Int(sysSendMmsg(sockfd, msgvec, vlen, flags))
        }
    }

    @inline(never)
    public static func recvmmsg(sockfd: CInt, msgvec: UnsafeMutablePointer<MMsgHdr>, vlen: CUnsignedInt, flags: CInt, timeout: UnsafeMutablePointer<timespec>?) throws -> IOResult<Int> {
        return try wrapSyscallMayBlock {
            Int(sysRecvMmsg(sockfd, msgvec, vlen, flags, timeout))
        }
    }

    @inline(never)
    public static func getpeername(socket: CInt, address: UnsafeMutablePointer<sockaddr>, addressLength: UnsafeMutablePointer<socklen_t>) throws {
        _ = try wrapSyscall {
            return sysGetpeername(socket, address, addressLength)
        }
    }

    @inline(never)
    public static func getsockname(socket: CInt, address: UnsafeMutablePointer<sockaddr>, addressLength: UnsafeMutablePointer<socklen_t>) throws {
        _ = try wrapSyscall {
            return sysGetsockname(socket, address, addressLength)
        }
    }

    @inline(never)
    public static func getifaddrs(_ addrs: UnsafeMutablePointer<UnsafeMutablePointer<ifaddrs>?>) throws {
        _ = try wrapSyscall {
            sysGetifaddrs(addrs)
        }
    }

}

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
internal enum KQueue {

    // TODO: Figure out how to specify a typealias to the kevent struct without run into trouble with the swift compiler

    @inline(never)
    public static func kqueue() throws -> CInt {
        return try wrapSyscall {
            Darwin.kqueue()
        }
    }

    @inline(never)
    public static func kevent(kq: CInt, changelist: UnsafePointer<kevent>?, nchanges: CInt, eventlist: UnsafeMutablePointer<kevent>?, nevents: CInt, timeout: UnsafePointer<Darwin.timespec>?) throws -> CInt {
        return try wrapSyscall {
            sysKevent(kq, changelist, nchanges, eventlist, nevents, timeout)
        }
    }
}
#endif
