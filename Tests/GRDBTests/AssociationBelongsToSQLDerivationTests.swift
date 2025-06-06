import XCTest
import GRDB

// A -> B
private struct A : TableRecord {
    static let databaseTableName = "a"
    static let b = belongsTo(B.self)
    static let restrictedB1 = belongsTo(RestrictedB1.self)
    static let restrictedB2 = belongsTo(RestrictedB2.self)
    static let extendedB = belongsTo(ExtendedB.self)
    
    enum Columns {
        static let id = Column("id")
        static let bid = Column("idb")
    }
}

private struct B : TableRecord {
    static let a = hasOne(A.self)
    static let databaseTableName = "b"
    
    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
    }
}

private struct RestrictedB1 : TableRecord {
    static let databaseTableName = "b"
    static var databaseSelection: [any SQLSelectable] { [Column("name")] }
}

private struct RestrictedB2 : TableRecord {
    static let databaseTableName = "b"
    static var databaseSelection: [any SQLSelectable] { [.allColumns(excluding: ["id"])] }
}

private struct ExtendedB : TableRecord {
    static let databaseTableName = "b"
    static var databaseSelection: [any SQLSelectable] { [.allColumns, .rowID] }
}

/// Test SQL generation
class AssociationBelongsToSQLDerivationTests: GRDBTestCase {
    
    override func setup(_ dbWriter: some DatabaseWriter) throws {
        try dbWriter.write { db in
            try db.create(table: "b") { t in
                t.primaryKey("id", .integer)
                t.column("name", .text)
            }
            try db.create(table: "a") { t in
                t.primaryKey("id", .integer)
                t.column("bid", .integer).references("b")
            }
        }
    }
    
    func testDefaultSelection() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            try assertEqualSQL(db, A.including(required: A.b), """
                SELECT "a".*, "b".* \
                FROM "a" \
                JOIN "b" ON "b"."id" = "a"."bid"
                """)
            try assertEqualSQL(db, A.including(required: A.restrictedB1), """
                SELECT "a".*, "b"."name" \
                FROM "a" \
                JOIN "b" ON "b"."id" = "a"."bid"
                """)
            try assertEqualSQL(db, A.including(required: A.restrictedB2), """
                SELECT "a".*, "b"."name" \
                FROM "a" \
                JOIN "b" ON "b"."id" = "a"."bid"
                """)
            try assertEqualSQL(db, A.including(required: A.extendedB), """
                SELECT "a".*, "b".*, "b"."rowid" \
                FROM "a" \
                JOIN "b" ON "b"."id" = "a"."bid"
                """)
        }
    }
    
    func testCustomSelection() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                let request = A.including(required: A.b
                    .select(Column("name")))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b"."name" \
                    FROM "a" \
                    JOIN "b" ON "b"."id" = "a"."bid"
                    """)
            }
            do {
                let request = A.including(required: A.b
                    .select(
                        .allColumns,
                        .rowID))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".*, "b"."rowid" \
                    FROM "a" \
                    JOIN "b" ON "b"."id" = "a"."bid"
                    """)
            }
            do {
                let aAlias = TableAlias()
                let request = A
                    .aliased(aAlias)
                    .including(required: A.b
                        .select(
                            Column("name"),
                            (Column("id") + aAlias[Column("id")]).forKey("foo")))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b"."name", "b"."id" + "a"."id" AS "foo" \
                    FROM "a" \
                    JOIN "b" ON "b"."id" = "a"."bid"
                    """)
            }
            #if compiler(>=6.1)
            do {
                let aAlias = TableAlias<A>()
                let request = A
                    .aliased(aAlias)
                    .including(required: A.b
                        .select { [
                            $0.name,
                            ($0.id + aAlias.id).forKey("foo")
                        ] })
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b"."name", "b"."id" + "a"."id" AS "foo" \
                    FROM "a" \
                    JOIN "b" ON "b"."id" = "a"."bid"
                    """)
            }
            #endif
        }
    }
    
    func testFilteredAssociationImpactsJoinOnClause() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                let request = A.including(required: A.b.filter(Column("name") != nil))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND ("b"."name" IS NOT NULL)
                    """)
            }
            do {
                let request = A.including(required: A.b.filter(key: 1))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND ("b"."id" = 1)
                    """)
            }
            do {
                let request = A.including(required: A.b.filter(keys: [1, 2, 3]))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND ("b"."id" IN (1, 2, 3))
                    """)
            }
            do {
                let alias = TableAlias()
                let request = A
                    .aliased(alias)
                    .including(required: A.b
                        .filter([alias[Column("id")], Column("id"), 42].contains(Column("id"))))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND ("b"."id" IN ("a"."id", "b"."id", 42))
                    """)
            }
            #if compiler(>=6.1)
            do {
                let alias = TableAlias<A>()
                let request = A
                    .aliased(alias)
                    .including(required: A.b
                        .filter { [alias.id, $0.id, 42].contains($0.id) })
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND ("b"."id" IN ("a"."id", "b"."id", 42))
                    """)
            }
            #endif
            do {
                let request = A.including(required: A.b.filter(key: ["id": 1]))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND ("b"."id" = 1)
                    """)
            }
            do {
                let request = A.including(required: A.b.filter(keys: [["id": 1], ["id": 2]]))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON ("b"."id" = "a"."bid") AND (("b"."id" = 1) OR ("b"."id" = 2))
                    """)
            }
            do {
                let bAlias = TableAlias(name: "customB")
                let request = A.including(required: A.b
                    .aliased(bAlias)
                    .filter(sql: "customB.name = ?", arguments: ["foo"]))
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "customB".* \
                    FROM "a" \
                    JOIN "b" "customB" ON ("customB"."id" = "a"."bid") AND (customB.name = 'foo')
                    """)
            }
        }
    }
    
    func testFilterAssociationInWhereClause() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            do {
                let bAlias = TableAlias()
                let request = A
                    .including(required: A.b.aliased(bAlias))
                    .filter(bAlias[Column("name")] != nil)
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON "b"."id" = "a"."bid" \
                    WHERE "b"."name" IS NOT NULL
                    """)
            }
            #if compiler(>=6.1)
            do {
                let bAlias = TableAlias<B>()
                let request = A
                    .including(required: A.b.aliased(bAlias))
                    .filter { _ in bAlias.name != nil }
                try assertEqualSQL(db, request, """
                    SELECT "a".*, "b".* \
                    FROM "a" \
                    JOIN "b" ON "b"."id" = "a"."bid" \
                    WHERE "b"."name" IS NOT NULL
                    """)
            }
            #endif
        }
    }
    
    func testAssociationOrderBubbleUp() throws {
        let dbQueue = try makeDatabaseQueue()
        try dbQueue.inDatabase { db in
            let aBase = A.all().aliased(TableAlias(name: "a"))
            let abBase = A.b.aliased(TableAlias(name: "ab"))
            let abaBase = B.a.aliased(TableAlias(name: "aba"))
            
            let aTransforms = [
                { (r: QueryInterfaceRequest<A>) in return r },
                { (r: QueryInterfaceRequest<A>) in return r.order(Column("id")) },
                { (r: QueryInterfaceRequest<A>) in return r.order(Column("id")).reversed() },
            ]
            let abTransforms = [
                { (r: BelongsToAssociation<A, B>) in return r },
                { (r: BelongsToAssociation<A, B>) in return r.order(Column("name"), Column("id").desc) },
                { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).order(Column("id").desc) },
                { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).reversed() },
                { (r: BelongsToAssociation<A, B>) in return r.reversed() },
            ]
            let abaTransforms = [
                { (r: HasOneAssociation<B, A>) in return r },
                { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) },
                { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() },
            ]
            
            var sqls: [String] = []
            for aTransform in aTransforms {
                for abTransform in abTransforms {
                    for abaTransform in abaTransforms {
                        let request = aTransform(aBase)
                            .including(required: abTransform(abBase)
                                .including(required: abaTransform(abaBase)))
                        try sqls.append(request.build(db).sql)
                    }
                }
            }
            
            let prefix = """
                SELECT "a".*, "ab".*, "aba".* \
                FROM "a" \
                JOIN "b" "ab" ON "ab"."id" = "a"."bid" \
                JOIN "a" "aba" ON "aba"."bid" = "ab"."id"
                """
            let orderClauses = sqls.map { sql -> String in
                let prefixEndIndex = sql.index(sql.startIndex, offsetBy: prefix.count)
                return String(sql.suffix(from: prefixEndIndex))
            }
            XCTAssertEqual(orderClauses, [
                // a: { (r: QueryInterfaceRequest<A>) in return r },
                // ab: { (r: BelongsToAssociation<A, B>) in return r }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                "",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name"), Column("id").desc) }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"ab\".\"name\", \"ab\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"ab\".\"name\", \"ab\".\"id\" DESC, \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"ab\".\"name\", \"ab\".\"id\" DESC, \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).order(Column("id").desc) }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"ab\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"ab\".\"id\" DESC, \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"ab\".\"id\" DESC, \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).reversed() }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"ab\".\"name\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"ab\".\"name\" DESC, \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"ab\".\"name\" DESC, \"aba\".\"id\"",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.reversed() }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                "",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"aba\".\"id\"",
                
                
                // a: { (r: QueryInterfaceRequest<A>) in return r.order(Column("id")) },
                // ab: { (r: BelongsToAssociation<A, B>) in return r }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\", \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\", \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name"), Column("id").desc) }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\", \"ab\".\"name\", \"ab\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\", \"ab\".\"name\", \"ab\".\"id\" DESC, \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\", \"ab\".\"name\", \"ab\".\"id\" DESC, \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).order(Column("id").desc) }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\", \"ab\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\", \"ab\".\"id\" DESC, \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\", \"ab\".\"id\" DESC, \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).reversed() }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\", \"ab\".\"name\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\", \"ab\".\"name\" DESC, \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\", \"ab\".\"name\" DESC, \"aba\".\"id\"",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.reversed() }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\", \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\", \"aba\".\"id\"",
                
                
                // a: { (r: QueryInterfaceRequest<A>) in return r.order(Column("id")).reversed() }
                // ab: { (r: BelongsToAssociation<A, B>) in return r }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\" DESC, \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\" DESC, \"aba\".\"id\"",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name"), Column("id").desc) }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"name\" DESC, \"ab\".\"id\" ASC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"name\" DESC, \"ab\".\"id\" ASC, \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"name\" DESC, \"ab\".\"id\" ASC, \"aba\".\"id\"",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).order(Column("id").desc) }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"id\" ASC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"id\" ASC, \"aba\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"id\" ASC, \"aba\".\"id\"",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.order(Column("name")).reversed() }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"name\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"name\", \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\" DESC, \"ab\".\"name\", \"aba\".\"id\" DESC",
                
                // ab: { (r: BelongsToAssociation<A, B>) in return r.reversed() }
                // aba: { (r: HasOneAssociation<B, A>) in return r }
                " ORDER BY \"a\".\"id\" DESC",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")) }
                " ORDER BY \"a\".\"id\" DESC, \"aba\".\"id\"",
                // aba: { (r: HasOneAssociation<B, A>) in return r.order(Column("id")).reversed() }
                " ORDER BY \"a\".\"id\" DESC, \"aba\".\"id\" DESC",
            ])
        }
    }
    
    // TODO: Test if and only if we really want to build an association from any request
//    func testAssociationFromRequest() throws {
//        let dbQueue = try makeDatabaseQueue()
//        try dbQueue.inDatabase { db in
//            do {
//                let bRequest = B
//                    .filter(Column("name") != nil)
//                    .order(Column("id"))
//                let association = A.belongsTo(bRequest)
//                let request = A.including(required: association)
//                try assertEqualSQL(db, request, """
//                    SELECT "a".*, "b".* \
//                    FROM "a" \
//                    JOIN "b" ON (("b"."id" = "a"."bid") AND ("b"."name" IS NOT NULL)) \
//                    ORDER BY "b"."id"
//                    """)
//            }
//            do {
//                let bRequest = RestrictedB
//                    .filter(Column("name") != nil)
//                    .order(Column("id"))
//                let association = A.belongsTo(bRequest)
//                let request = A.including(required: association)
//                try assertEqualSQL(db, request, """
//                    SELECT "a".*, "b"."name" \
//                    FROM "a" \
//                    JOIN "b" ON (("b"."id" = "a"."bid") AND ("b"."name" IS NOT NULL)) \
//                    ORDER BY "b"."id"
//                    """)
//            }
//            do {
//                let bRequest = ExtendedB
//                    .select([Column("name")])
//                    .filter(Column("name") != nil)
//                    .order(Column("id"))
//                let association = A.belongsTo(bRequest)
//                let request = A.including(required: association)
//                try assertEqualSQL(db, request, """
//                    SELECT "a".*, "b"."name" \
//                    FROM "a" \
//                    JOIN "b" ON (("b"."id" = "a"."bid") AND ("b"."name" IS NOT NULL)) \
//                    ORDER BY "b"."id"
//                    """)
//            }
//        }
//    }
}
