import Foundation
import TraccioCore

/// `CategoriesAPI` stub, mirroring `APIClient+Categories.swift`.
extension FakeAPIClient {
    /// A recorded `renameCategory(id:name:)` call, for asserting exactly
    /// which category was renamed to what.
    struct RecordedRename: Equatable {
        let id: UUID
        let name: String
    }

    /// A recorded `createCategory(name:parentID:color:icon:)` call.
    struct RecordedCategoryCreate: Equatable {
        let name: String
        let parentID: UUID?
        let color: PaletteColor?
        let icon: CategoryIcon?
    }

    /// A recorded `setCategoryAppearance(id:color:icon:)` call.
    struct RecordedCategoryAppearance: Equatable {
        let id: UUID
        let color: PaletteColor
        let icon: CategoryIcon?
    }

    /// A recorded `moveCategory(id:parentID:)` call.
    struct RecordedCategoryMove: Equatable {
        let id: UUID
        let parentID: UUID?
    }

    func setCategories(_ categories: [CategoryResponse]) {
        categoriesToReturn = categories
    }

    func setCategoriesError(_ error: Error) {
        categoriesError = error
    }

    func setSeedDefaultCategoriesResult(_ categories: [CategoryResponse]) {
        seedDefaultCategoriesToReturn = categories
    }

    func setSeedDefaultCategoriesError(_ error: Error) {
        seedDefaultCategoriesError = error
    }

    func setCreateCategoryResult(_ category: CategoryResponse) {
        createCategoryToReturn = category
    }

    func setCreateCategoryError(_ error: Error) {
        createCategoryError = error
    }

    func setRenameCategoryResult(_ category: CategoryResponse) {
        renameCategoryToReturn = category
    }

    func setRenameCategoryError(_ error: Error) {
        renameCategoryError = error
    }

    func setDeleteCategoryError(_ error: Error) {
        deleteCategoryError = error
    }

    func setCategoryAppearanceResult(_ category: CategoryResponse) {
        categoryAppearanceToReturn = category
    }

    func setCategoryAppearanceError(_ error: Error) {
        categoryAppearanceError = error
    }

    func setMoveCategoryResult(_ category: CategoryResponse) {
        moveCategoryToReturn = category
    }

    func setMoveCategoryError(_ error: Error) {
        moveCategoryError = error
    }

    func categories() async throws -> [CategoryResponse] {
        categoriesFetchCount += 1
        if let categoriesError { throw categoriesError }
        return categoriesToReturn
    }

    func seedDefaultCategories() async throws -> [CategoryResponse] {
        if let seedDefaultCategoriesError { throw seedDefaultCategoriesError }
        return seedDefaultCategoriesToReturn
    }

    func createCategory(
        name: String, parentID: UUID?, color: PaletteColor?, icon: CategoryIcon?
    ) async throws -> CategoryResponse {
        if let createCategoryError { throw createCategoryError }
        createdCategoryNames.append(name)
        createCategoryRequests.append(
            RecordedCategoryCreate(name: name, parentID: parentID, color: color, icon: icon)
        )
        guard let createCategoryToReturn else { throw NotConfigured() }
        return createCategoryToReturn
    }

    func renameCategory(id: UUID, name: String) async throws -> CategoryResponse {
        if let renameCategoryError { throw renameCategoryError }
        renamedCategories.append(RecordedRename(id: id, name: name))
        guard let renameCategoryToReturn else { throw NotConfigured() }
        return renameCategoryToReturn
    }

    func setCategoryAppearance(
        id: UUID, color: PaletteColor, icon: CategoryIcon?
    ) async throws -> CategoryResponse {
        if let categoryAppearanceError { throw categoryAppearanceError }
        categoryAppearanceUpdates.append(RecordedCategoryAppearance(id: id, color: color, icon: icon))
        guard let categoryAppearanceToReturn else { throw NotConfigured() }
        return categoryAppearanceToReturn
    }

    func moveCategory(id: UUID, parentID: UUID?) async throws -> CategoryResponse {
        if let moveCategoryError { throw moveCategoryError }
        movedCategories.append(RecordedCategoryMove(id: id, parentID: parentID))
        guard let moveCategoryToReturn else { throw NotConfigured() }
        return moveCategoryToReturn
    }

    func deleteCategory(id: UUID) async throws {
        if let deleteCategoryError { throw deleteCategoryError }
        deletedCategoryIDs.append(id)
    }
}
