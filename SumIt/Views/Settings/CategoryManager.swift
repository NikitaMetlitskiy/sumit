import SwiftUI
import SwiftData

struct CategoryManagerSheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) var categories: [Category]
    @Environment(\.dismiss) var dismiss
    @State private var showAdd = false
    @State private var mode: CategoryMode = .normal

    enum CategoryMode { case normal, reorder, delete }

    var editMode: EditMode { mode == .normal ? .inactive : .active }

    var body: some View {
        NavigationView {
            List {
                ForEach(categories) { cat in
                    HStack(spacing: 12) {
                        Circle().fill(cat.color.opacity(0.15)).frame(width: 36, height: 36)
                            .overlay(Image(systemName: cat.icon)
                                .font(.system(size: 14, weight: .light))
                                .foregroundColor(cat.color))
                        Text(cat.displayName).font(.system(size: 15))
                        Spacer()
                        if cat.isDefault {
                            Text(L("system_cat")).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                    .deleteDisabled(mode == .reorder || cat.isDefault)
                    .moveDisabled(mode == .delete)
                }
                .onMove { indices, newOffset in
                    var cats = Array(categories)
                    cats.move(fromOffsets: indices, toOffset: newOffset)
                    for (i, c) in cats.enumerated() { c.sortOrder = i }
                    try? modelContext.save()
                    store.loadCategories()
                }
                .onDelete { indices in
                    indices.map { categories[$0] }
                        .filter { !$0.isDefault }
                        .forEach { modelContext.delete($0) }
                    try? modelContext.save()
                    store.loadCategories()
                }
            }
            .environment(\.editMode, .constant(editMode))
            .navigationTitle(L("categories"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("close")) { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if mode != .normal {
                        Button(L("done")) { withAnimation { mode = .normal } }
                            .fontWeight(.semibold)
                    } else {
                        Menu {
                            Button { withAnimation(.none) { showAdd = true } } label: {
                                Label(L("add"), systemImage: "plus")
                            }
                            Button { withAnimation { mode = .reorder } } label: {
                                Label(L("reorder"), systemImage: "arrow.up.arrow.down")
                            }
                            Button(role: .destructive) {
                                withAnimation { mode = .delete }
                            } label: {
                                Label(L("delete"), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 18))
                        }
                    }
                }
            }
            .sheet(isPresented: $showAdd) { AddCategorySheet(store: store) }
        }
    }
}

struct AddCategorySheet: View {
    @ObservedObject var store: AppStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var selectedIcon = "tag.fill"
    @State private var selectedColor = "5271B4"

    let icons = ["tag.fill","cart.fill","car.fill","fork.knife","book.fill","cross.fill",
                 "house.fill","tv.fill","airplane","gift.fill","bolt.fill","arrow.clockwise",
                 "music.note","gamecontroller.fill","pawprint.fill","figure.walk"]
    let colors = ["FF6B6B","4ECDC4","45B7D1","96CEB4","A29BFE","DDA0DD",
                  "F0A500","FD79A8","00CEC9","6C5CE7","00B894","0984E3"]

    var body: some View {
        NavigationView {
            Form {
                Section(L("name")) {
                    TextField(L("category_name_hint"), text: $name)
                }
                Section(L("icon")) {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Button { selectedIcon = icon } label: {
                                Image(systemName: icon).font(.system(size: 20, weight: .light))
                                    .frame(width: 44, height: 44)
                                    .background(selectedIcon == icon ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedIcon == icon ? Color.accentColor : Color.clear, lineWidth: 1.5))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }
                Section(L("color")) {
                    LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 6), spacing: 12) {
                        ForEach(colors, id: \.self) { hex in
                            Button { selectedColor = hex } label: {
                                Circle().fill(Color(hex: hex) ?? .blue).frame(width: 36, height: 36)
                                    .overlay(Circle()
                                        .stroke(Color.primary.opacity(selectedColor == hex ? 0.5 : 0), lineWidth: 2.5)
                                        .padding(2))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 4)
                }
            }
            .navigationTitle(L("new_category"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("add")) {
                        let cat = Category(name: name, icon: selectedIcon, colorHex: selectedColor, sortOrder: 99)
                        modelContext.insert(cat)
                        try? modelContext.save()
                        store.loadCategories()
                        let snap = cat.snapshot(userId: AuthService.shared.userId)
                        Task { try? await SupabaseService.shared.saveCategory(snap) }
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
