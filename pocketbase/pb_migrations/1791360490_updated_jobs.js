/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const dao = new Dao(db)
  const collection = dao.findCollectionByNameOrId("3i6w249bum5mm2d")

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "cwdduts4",
    "name": "log_flat",
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
    "id": "uxb3gism",
    "name": "log_organize",
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
  collection.schema.removeField("cwdduts4")

  // remove
  collection.schema.removeField("uxb3gism")

  return dao.saveCollection(collection)
})
