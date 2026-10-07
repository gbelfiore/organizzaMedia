/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const dao = new Dao(db)
  const collection = dao.findCollectionByNameOrId("3i6w249bum5mm2d")

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "t87mn4fj",
    "name": "log_others",
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
  collection.schema.removeField("t87mn4fj")

  return dao.saveCollection(collection)
})
