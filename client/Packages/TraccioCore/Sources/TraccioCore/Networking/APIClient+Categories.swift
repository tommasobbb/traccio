import Foundation

/// Category endpoints — one slice of `APIClientProtocol`.
public protocol CategoriesAPI: Sendable {
    func categories() async throws -> [CategoryResponse]
    func seedDefaultCategories() async throws -> [CategoryResponse]
    func createCategory(
        name: String, parentID: UUID?, color: PaletteColor?, icon: CategoryIcon?
    ) async throws -> CategoryResponse
    func renameCategory(id: UUID, name: String) async throws -> CategoryResponse
    func setCategoryAppearance(
        id: UUID, color: PaletteColor, icon: CategoryIcon?
    ) async throws -> CategoryResponse
    func moveCategory(id: UUID, parentID: UUID?) async throws -> CategoryResponse
    func deleteCategory(id: UUID) async throws
}

// Category endpoints — split out of APIClient.swift (2026-09-07). The transport
// helpers (`get`/`post`/`send`/`delete`) live on the primary file.
extension APIClient: CategoriesAPI {
    /// Fetch the caller's categories.
    ///
    /// Returns
    /// -------
    /// The decoded categories from `GET /categories`.
    public func categories() async throws -> [CategoryResponse] {
        let envelope: CategoriesResponse = try await get("categories")
        return envelope.categories
    }

    /// Seed the caller's default category set.
    ///
    /// Mirrors `POST /categories/defaults` — the unblock for a category
    /// picker on a fresh database with no categories yet. Idempotent on the
    /// backend for categories already present.
    ///
    /// Returns
    /// -------
    /// The full set of categories after seeding.
    public func seedDefaultCategories() async throws -> [CategoryResponse] {
        let envelope: CategoriesResponse = try await post("categories/defaults")
        return envelope.categories
    }

    /// Create a category.
    ///
    /// Mirrors `POST /categories`, `201 Created` with the created category.
    /// The backend validates the name (blank/too-long → `422`) and uniqueness
    /// (a collision → `409 category_name_taken`); the client does not
    /// pre-check either. `parentID` nests the new category under an existing
    /// root (ADR 0018); a `404` if it is unknown, a `422
    /// category_depth_exceeded` if it is itself a child.
    ///
    /// Parameters
    /// ----------
    /// name:
    ///     The category's name.
    /// parentID:
    ///     The root to nest under, or `nil` to create a root.
    /// color:
    ///     The category's colour, or `nil` to let the backend default it.
    /// icon:
    ///     The category's icon, or `nil` to leave it unset.
    ///
    /// Returns
    /// -------
    /// The created category.
    public func createCategory(
        name: String, parentID: UUID? = nil, color: PaletteColor? = nil, icon: CategoryIcon? = nil
    ) async throws -> CategoryResponse {
        try await post(
            "categories",
            body: CreateCategoryRequest(name: name, parentID: parentID, color: color, icon: icon)
        )
    }

    /// Rename a category — its only mutation.
    ///
    /// Mirrors `POST /categories/{id}/rename`, `200` with the category under
    /// its new name. A `404` if the category is unknown or not the caller's;
    /// a `409 category_name_taken` if the new name collides with a different
    /// one of the caller's categories.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to rename.
    /// name:
    ///     The new name.
    ///
    /// Returns
    /// -------
    /// The category under its new name.
    public func renameCategory(id: UUID, name: String) async throws -> CategoryResponse {
        try await post("categories/\(id.uuidString)/rename", body: RenameCategoryRequest(name: name))
    }

    /// Set a category's colour and icon.
    ///
    /// Mirrors `POST /categories/{id}/appearance`, `200` with the category
    /// under its new appearance. A full replace: both fields are sent
    /// together. A `404` if the category is unknown or not the caller's.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to restyle.
    /// color:
    ///     The new colour.
    /// icon:
    ///     The new icon, or `nil` to clear it.
    ///
    /// Returns
    /// -------
    /// The category under its new appearance.
    public func setCategoryAppearance(
        id: UUID, color: PaletteColor, icon: CategoryIcon?
    ) async throws -> CategoryResponse {
        try await post(
            "categories/\(id.uuidString)/appearance",
            body: SetCategoryAppearanceRequest(color: color, icon: icon)
        )
    }

    /// Reparent a category — make it a root, or nest it under one.
    ///
    /// Mirrors `POST /categories/{id}/move`, `200` with the category under
    /// its new parent. A `404` if the category, or the new parent, is
    /// unknown or not the caller's; a `422` if the new parent is the
    /// category itself or is itself a child (ADR 0018); a `409` if the
    /// category being moved has children of its own and a non-`nil` parent
    /// was given.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to move.
    /// parentID:
    ///     The new parent, or `nil` to make it a root.
    ///
    /// Returns
    /// -------
    /// The category under its new parent.
    public func moveCategory(id: UUID, parentID: UUID?) async throws -> CategoryResponse {
        try await post(
            "categories/\(id.uuidString)/move", body: MoveCategoryRequest(parentID: parentID)
        )
    }

    /// Delete a category.
    ///
    /// Mirrors `DELETE /categories/{id}`, `204 No Content` on success. A
    /// `404` if the category is unknown or not the caller's; a
    /// `409 category_in_use` if it is confirmed on any of the caller's
    /// transactions — that refusal is not something the client pre-checks,
    /// since only the backend knows every confirmation.
    ///
    /// Parameters
    /// ----------
    /// id:
    ///     The category to delete.
    public func deleteCategory(id: UUID) async throws {
        try await delete("categories/\(id.uuidString)")
    }
}
