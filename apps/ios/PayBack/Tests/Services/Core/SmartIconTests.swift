import XCTest
@testable import PayBack

/// Tests for SmartIcon service
///
/// This test suite validates:
/// - Transportation keywords (uber, taxi, lyft)
/// - Accommodation keywords (hotel, airbnb)
/// - Food keywords (restaurant, dinner, pizza, coffee)
/// - Case-insensitive matching
/// - Plural forms
/// - Default icon for unknown categories
///
/// Related Requirements: R8, R30
final class SmartIconTests: XCTestCase {

    // MARK: - Test transportation keywords

    func test_icon_uber_returnsCarIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Uber ride")

        // Assert
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    func test_icon_lyft_returnsCarIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Lyft to airport")

        // Assert
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    func test_icon_taxi_returnsCarIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Taxi fare")

        // Assert
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    func test_icon_transportationKeyword_hasPurpleBackground() {
        // Act
        let icon = SmartIcon.icon(for: "uber")

        // Assert
        XCTAssertEqual(icon.background, .purple)
    }

    // MARK: - Test accommodation keywords

    func test_icon_hotel_returnsBedIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Hotel booking")

        // Assert
        XCTAssertEqual(icon.systemName, "bed.double.fill")
    }

    func test_icon_airbnb_returnsBedIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Airbnb stay")

        // Assert
        XCTAssertEqual(icon.systemName, "bed.double.fill")
    }

    func test_icon_accommodationKeyword_hasPinkBackground() {
        // Act
        let icon = SmartIcon.icon(for: "hotel")

        // Assert
        XCTAssertEqual(icon.background, .pink)
    }

    // MARK: - Test food keywords

    func test_icon_restaurant_returnsForkKnifeIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Restaurant dinner")

        // Assert
        XCTAssertEqual(icon.systemName, "fork.knife")
    }

    func test_icon_dinner_returnsForkKnifeIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Dinner with friends")

        // Assert
        XCTAssertEqual(icon.systemName, "fork.knife")
    }

    func test_icon_pizza_returnsForkKnifeIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Pizza delivery")

        // Assert
        XCTAssertEqual(icon.systemName, "fork.knife")
    }

    func test_icon_food_returnsForkKnifeIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Food shopping")

        // Assert
        XCTAssertEqual(icon.systemName, "fork.knife")
    }

    func test_icon_foodKeyword_hasOrangeBackground() {
        // Act
        let icon = SmartIcon.icon(for: "dinner")

        // Assert
        XCTAssertEqual(icon.background, .orange)
    }

    func test_icon_coffee_returnsCupIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Coffee shop")

        // Assert
        XCTAssertEqual(icon.systemName, "cup.and.saucer.fill")
    }

    func test_icon_starbucks_returnsCupIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Starbucks")

        // Assert
        XCTAssertEqual(icon.systemName, "cup.and.saucer.fill")
    }

    func test_icon_coffeeKeyword_hasBrownBackground() {
        // Act
        let icon = SmartIcon.icon(for: "coffee")

        // Assert
        XCTAssertEqual(icon.background, .brown)
    }

    // MARK: - Test additional categories

    func test_icon_flight_returnsAirplaneIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Flight tickets")

        // Assert
        XCTAssertEqual(icon.systemName, "airplane")
    }

    func test_icon_travel_returnsAirplaneIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Travel expenses")

        // Assert
        XCTAssertEqual(icon.systemName, "airplane")
    }

    func test_icon_plane_returnsAirplaneIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Plane ticket")

        // Assert
        XCTAssertEqual(icon.systemName, "airplane")
    }

    func test_icon_grocer_returnsCartIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Grocery shopping")

        // Assert
        XCTAssertEqual(icon.systemName, "cart.fill")
    }

    func test_icon_groceries_returnsCartIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Groceries")

        // Assert
        XCTAssertEqual(icon.systemName, "cart.fill")
    }

    func test_icon_groceryKeyword_hasGreenBackground() {
        // Act
        let icon = SmartIcon.icon(for: "grocer")

        // Assert
        XCTAssertEqual(icon.background, .green)
    }

    func test_icon_rent_returnsHouseIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Rent payment")

        // Assert
        XCTAssertEqual(icon.systemName, "house.fill")
    }

    func test_icon_mortgage_returnsHouseIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Mortgage")

        // Assert
        XCTAssertEqual(icon.systemName, "house.fill")
    }

    func test_icon_housingKeyword_hasIndigoBackground() {
        // Act
        let icon = SmartIcon.icon(for: "rent")

        // Assert
        XCTAssertEqual(icon.background, .indigo)
    }

    // MARK: - Test case-insensitive matching

    func test_icon_uppercaseUber_returnsCarIcon() {
        // Act
        let icon = SmartIcon.icon(for: "UBER")

        // Assert
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    func test_icon_mixedCaseTaxi_returnsCarIcon() {
        // Act
        let icon = SmartIcon.icon(for: "TaXi")

        // Assert
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    func test_icon_uppercaseHotel_returnsBedIcon() {
        // Act
        let icon = SmartIcon.icon(for: "HOTEL")

        // Assert
        XCTAssertEqual(icon.systemName, "bed.double.fill")
    }

    func test_icon_mixedCaseCoffee_returnsCupIcon() {
        // Act
        let icon = SmartIcon.icon(for: "CoFfEe")

        // Assert
        XCTAssertEqual(icon.systemName, "cup.and.saucer.fill")
    }

    func test_icon_caseInsensitive_sameIconForDifferentCases() {
        // Act
        let lowerIcon = SmartIcon.icon(for: "pizza")
        let upperIcon = SmartIcon.icon(for: "PIZZA")
        let mixedIcon = SmartIcon.icon(for: "PiZzA")

        // Assert
        XCTAssertEqual(lowerIcon.systemName, upperIcon.systemName)
        XCTAssertEqual(lowerIcon.systemName, mixedIcon.systemName)
        XCTAssertEqual(lowerIcon.background, upperIcon.background)
        XCTAssertEqual(lowerIcon.background, mixedIcon.background)
    }

    // MARK: - Test plural forms

    func test_icon_taxis_returnsCarIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Taxis")

        // Assert
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    func test_icon_hotels_returnsBedIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Hotels")

        // Assert
        XCTAssertEqual(icon.systemName, "bed.double.fill")
    }

    func test_icon_restaurants_returnsForkKnifeIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Restaurants")

        // Assert
        XCTAssertEqual(icon.systemName, "fork.knife")
    }

    func test_icon_flights_returnsAirplaneIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Flights")

        // Assert
        XCTAssertEqual(icon.systemName, "airplane")
    }

    // MARK: - Test default icon for unknown categories

    func test_icon_unknownCategory_returnsTagIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Random expense")

        // Assert
        XCTAssertEqual(icon.systemName, "tag.fill")
    }

    func test_icon_emptyString_returnsTagIcon() {
        // Act
        let icon = SmartIcon.icon(for: "")

        // Assert
        XCTAssertEqual(icon.systemName, "tag.fill")
    }

    func test_icon_numbersOnly_returnsTagIcon() {
        // Act
        let icon = SmartIcon.icon(for: "12345")

        // Assert
        XCTAssertEqual(icon.systemName, "tag.fill")
    }

    func test_icon_specialCharacters_returnsTagIcon() {
        // Act
        let icon = SmartIcon.icon(for: "!@#$%")

        // Assert
        XCTAssertEqual(icon.systemName, "tag.fill")
    }

    func test_icon_unknownKeyword_returnsTagIcon() {
        // Act
        let icon = SmartIcon.icon(for: "Random miscellaneous expense")

        // Assert
        XCTAssertEqual(icon.systemName, "tag.fill")
    }

    // MARK: - Test keyword matching in context

    func test_icon_keywordInSentence_matchesCorrectly() {
        // Act
        let icon1 = SmartIcon.icon(for: "Took an uber to the meeting")
        let icon2 = SmartIcon.icon(for: "Stayed at a nice hotel downtown")
        let icon3 = SmartIcon.icon(for: "Had dinner at the restaurant")

        // Assert
        XCTAssertEqual(icon1.systemName, "car.fill")
        XCTAssertEqual(icon2.systemName, "bed.double.fill")
        XCTAssertEqual(icon3.systemName, "fork.knife")
    }

    func test_icon_multipleKeywords_matchesFirst() {
        // Act - "uber" appears before "hotel" in the matching logic
        let icon = SmartIcon.icon(for: "Uber to hotel")

        // Assert - Should match uber (car) since it's checked first
        XCTAssertEqual(icon.systemName, "car.fill")
    }

    // MARK: - Test foreground color

    func test_icon_allIcons_haveWhiteForeground() {
        // Act
        let icons = [
            SmartIcon.icon(for: "uber"),
            SmartIcon.icon(for: "hotel"),
            SmartIcon.icon(for: "coffee"),
            SmartIcon.icon(for: "dinner"),
            SmartIcon.icon(for: "flight"),
            SmartIcon.icon(for: "grocer"),
            SmartIcon.icon(for: "rent"),
            SmartIcon.icon(for: "unknown")
        ]

        // Assert
        for icon in icons {
            XCTAssertEqual(icon.foreground, .white, "All icons should have white foreground")
        }
    }
}
