import Testing
import Foundation
@testable import TestSupport

@Suite("VMManager")
struct VMManagerTests {

    @Test func buildsTartRunArgs() {
        let args = VMManager.tartArguments(for: .run, vm: "my-vm")
        #expect(args == ["run", "my-vm", "--no-graphics", "--vnc-experimental"])
    }

    @Test func buildsTartCloneArgs() {
        let args = VMManager.tartArguments(for: .clone, vm: "base-image", destination: "my-vm")
        #expect(args == ["clone", "base-image", "my-vm"])
    }

    @Test func buildsTartStopArgs() {
        let args = VMManager.tartArguments(for: .stop, vm: "my-vm")
        #expect(args == ["stop", "my-vm"])
    }

    @Test func buildsTartDeleteArgs() {
        let args = VMManager.tartArguments(for: .delete, vm: "my-vm")
        #expect(args == ["delete", "my-vm"])
    }

    @Test func buildsTartListArgs() {
        let args = VMManager.tartArguments(for: .list, vm: "")
        #expect(args == ["list", "--format", "json"])
    }

    @Test func parsesVNCURLWithPasswordAndPort() {
        let output = "vnc://:s3cret@localhost:5901\n"
        let endpoint = VMManager.parseVNCURL(from: output)
        #expect(endpoint != nil)
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == 5901)
        #expect(endpoint?.password == "s3cret")
    }

    @Test func parsesVNCURLWithoutPassword() {
        let output = "vnc://localhost:5900\n"
        let endpoint = VMManager.parseVNCURL(from: output)
        #expect(endpoint != nil)
        #expect(endpoint?.host == "localhost")
        #expect(endpoint?.port == 5900)
        #expect(endpoint?.password == "")
    }

    @Test func parsesVNCURLFromMultilineOutput() {
        let output = """
        Waiting for VM to boot...
        vnc://:abc123@127.0.0.1:59432...
        Some other output
        """
        let endpoint = VMManager.parseVNCURL(from: output)
        #expect(endpoint != nil)
        #expect(endpoint?.password == "abc123")
        #expect(endpoint?.port == 59432)
    }

    @Test func returnsNilForNoVNCURL() {
        let output = "No VNC URL here\n"
        #expect(VMManager.parseVNCURL(from: output) == nil)
    }

    @Test func detectsVMInListOutput() {
        let json = """
        [{"Name":"guivision-test","State":"stopped","Disk":10737418240},
         {"Name":"other-vm","State":"running","Disk":10737418240}]
        """
        #expect(VMManager.vmExistsInList(vmName: "guivision-test", listOutput: json) == true)
    }

    @Test func detectsAbsentVMInListOutput() {
        let json = """
        [{"Name":"other-vm","State":"stopped","Disk":10737418240}]
        """
        #expect(VMManager.vmExistsInList(vmName: "guivision-test", listOutput: json) == false)
    }

    @Test func handlesEmptyList() {
        #expect(VMManager.vmExistsInList(vmName: "guivision-test", listOutput: "[]") == false)
    }

    @Test func detectsVMStateFromList() {
        let json = """
        [{"Name":"guivision-test","State":"running","Disk":10737418240}]
        """
        #expect(VMManager.vmStateInList(vmName: "guivision-test", listOutput: json) == "running")
    }

    @Test func returnsNilStateForAbsentVM() {
        let json = """
        [{"Name":"other-vm","State":"stopped","Disk":10737418240}]
        """
        #expect(VMManager.vmStateInList(vmName: "guivision-test", listOutput: json) == nil)
    }
}
