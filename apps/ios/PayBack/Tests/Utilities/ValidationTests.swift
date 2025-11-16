import XCTest
@testable import PayBack

final class ValidationTests: XCTestCase {
    
    func testEmailValidation() {
        let validator = Validator()
        
        XCTAssertTrue(validator.isValidEmail("test@example.com"))
        XCTAssertTrue(validator.isValidEmail("user.name@domain.co.uk"))
        XCTAssertTrue(validator.isValidEmail("first+last@test.org"))
        
        XCTAssertFalse(validator.isValidEmail("invalid.email"))
        XCTAssertFalse(validator.isValidEmail("@example.com"))
        XCTAssertFalse(validator.isValidEmail("test@"))
        XCTAssertFalse(validator.isValidEmail(""))
    }
    
    func testPasswordValidation() {
        let validator = Validator()
        
        XCTAssertTrue(validator.isValidPassword("SecurePass123!"))
        XCTAssertTrue(validator.isValidPassword("MyP@ssw0rd"))
        
        XCTAssertFalse(validator.isValidPassword("short"))
        XCTAssertFalse(validator.isValidPassword(""))
        XCTAssertFalse(validator.isValidPassword("12345"))
    }
    
    func testAmountValidation() {
        let validator = Validator()
        
        XCTAssertTrue(validator.isValidAmount(100.0))
        XCTAssertTrue(validator.isValidAmount(0.01))
        XCTAssertTrue(validator.isValidAmount(1000000.99))
        
        XCTAssertFalse(validator.isValidAmount(0))
        XCTAssertFalse(validator.isValidAmount(-50.0))
    }
    
    func testNameValidation() {
        let validator = Validator()
        
        XCTAssertTrue(validator.isValidName("John Doe"))
        XCTAssertTrue(validator.isValidName("Alice"))
        XCTAssertTrue(validator.isValidName("Bob Smith Jr."))
        
        XCTAssertFalse(validator.isValidName(""))
        XCTAssertFalse(validator.isValidName("  "))
        XCTAssertFalse(validator.isValidName("A"))
    }
    
    func testGroupNameValidation() {
        let validator = Validator()
        
        XCTAssertTrue(validator.isValidGroupName("Family Trip"))
        XCTAssertTrue(validator.isValidGroupName("Roommates 2024"))
        
        XCTAssertFalse(validator.isValidGroupName(""))
        XCTAssertFalse(validator.isValidGroupName("  "))
    }
}

class Validator {
    func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let predicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return predicate.evaluate(with: email)
    }
    
    func isValidPassword(_ password: String) -> Bool {
        return password.count >= 8
    }
    
    func isValidAmount(_ amount: Double) -> Bool {
        return amount > 0
    }
    
    func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2
    }
    
    func isValidGroupName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}
