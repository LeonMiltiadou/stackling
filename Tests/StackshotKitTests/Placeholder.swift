import Testing
@testable import StackshotKit

@Test func libraryRootIsInPictures() {
    #expect(Library.root.path.hasSuffix("Pictures/Stackshot"))
}
