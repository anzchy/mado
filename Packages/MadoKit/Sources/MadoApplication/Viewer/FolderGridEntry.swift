import MadoCore

extension ViewerSession {
    public func enterFolderGrid(items: [ItemID], sourceVersion: PreviewSourceVersion) {
        setInspectorVisible(false)
        imageLoader.close()
        beginBrowsing(items: items, sourceVersion: sourceVersion, scrollAnchor: nil)
    }
}
