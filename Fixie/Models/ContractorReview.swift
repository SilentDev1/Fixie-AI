// Models/ContractorReview.swift
// A single customer review for a Fixie Verified Pro.
// Fetched from contractors/{proId}/reviews/{reviewId}.
import Foundation

struct ContractorReview: Identifiable {
    let id:           String
    let rating:       Int       // 1–5
    let comment:      String
    let customerName: String
    let deviceModel:  String
    let date:         Date
}
