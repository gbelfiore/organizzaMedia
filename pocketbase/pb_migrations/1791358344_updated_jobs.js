/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const dao = new Dao(db)
  const collection = dao.findCollectionByNameOrId("3i6w249bum5mm2d")

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "bfcjxpy0",
    "name": "files_other",
    "type": "number",
    "required": false,
    "presentable": false,
    "unique": false,
    "options": {
      "min": null,
      "max": null,
      "noDecimal": false
    }
  }))

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "oxvpw2p1",
    "name": "other_exts",
    "type": "json",
    "required": false,
    "presentable": false,
    "unique": false,
    "options": {
      "maxSize": 2000000
    }
  }))

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "ilv1yfre",
    "name": "other_files",
    "type": "json",
    "required": false,
    "presentable": false,
    "unique": false,
    "options": {
      "maxSize": 2000000
    }
  }))

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "gou72cje",
    "name": "report_md",
    "type": "json",
    "required": false,
    "presentable": false,
    "unique": false,
    "options": {
      "maxSize": 2000000
    }
  }))

  return dao.saveCollection(collection)
}, (db) => {
  const dao = new Dao(db)
  const collection = dao.findCollectionByNameOrId("3i6w249bum5mm2d")

  // remove
  collection.schema.removeField("bfcjxpy0")

  // remove
  collection.schema.removeField("oxvpw2p1")

  // remove
  collection.schema.removeField("ilv1yfre")

  // remove
  collection.schema.removeField("gou72cje")

  return dao.saveCollection(collection)
})
