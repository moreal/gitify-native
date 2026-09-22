import ServiceManagement
import XCTest
@testable import Gitify

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testEnabledNotRegisteredRegisters() throws {
        let service = LoginItemServiceSpy(status: .notRegistered)

        try LoginItemController(service: service).reconcile(enabled: true)

        XCTAssertEqual(service.actions, [.register])
    }

    func testEnabledAlreadyEnabledDoesNothing() throws {
        let service = LoginItemServiceSpy(status: .enabled)

        try LoginItemController(service: service).reconcile(enabled: true)

        XCTAssertEqual(service.actions, [])
    }

    func testEnabledRequiresApprovalDoesNothing() throws {
        let service = LoginItemServiceSpy(status: .requiresApproval)

        try LoginItemController(service: service).reconcile(enabled: true)

        XCTAssertEqual(service.actions, [])
    }

    func testDisabledEnabledUnregisters() throws {
        let service = LoginItemServiceSpy(status: .enabled)

        try LoginItemController(service: service).reconcile(enabled: false)

        XCTAssertEqual(service.actions, [.unregister])
    }

    func testDisabledRequiresApprovalUnregisters() throws {
        let service = LoginItemServiceSpy(status: .requiresApproval)

        try LoginItemController(service: service).reconcile(enabled: false)

        XCTAssertEqual(service.actions, [.unregister])
    }

    func testDisabledNotRegisteredDoesNothing() throws {
        let service = LoginItemServiceSpy(status: .notRegistered)

        try LoginItemController(service: service).reconcile(enabled: false)

        XCTAssertEqual(service.actions, [])
    }
}

@MainActor
private final class LoginItemServiceSpy: LoginItemService {
    enum Action: Equatable {
        case register
        case unregister
    }

    let status: SMAppService.Status
    private(set) var actions: [Action] = []

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        actions.append(.register)
    }

    func unregister() throws {
        actions.append(.unregister)
    }
}
