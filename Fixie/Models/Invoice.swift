// Models/Invoice.swift
import Foundation

struct Invoice: Identifiable {
    let id:              String   // Firestore document ID
    let invoiceNumber:   String
    let jobId:           String
    let businessName:    String
    let lineItems:       [LineItem]
    let finalTotal:      Double
    let notes:           String
    let status:          String
    let issuedAt:        Date

    struct LineItem: Identifiable {
        let id:          String
        let description: String
        let amount:      Double
    }
}
