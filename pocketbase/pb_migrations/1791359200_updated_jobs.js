/// <reference path="../pb_data/types.d.ts" />
migrate((db) => {
  const dao = new Dao(db)
  const collection = dao.findCollectionByNameOrId("3i6w249bum5mm2d")

  // add
  collection.schema.addField(new SchemaField({
    "system": false,
    "id": "7zkiyfod",
    "name": "org_dir",
    "type": "text",
    "required": false,
    "presentable": false,
    "unique": false,
    "options": {
      "min": null,
      "max": null,
      "pattern": ""
    }
  }))

  return dao.saveCollection(collection)
}, (db) => {
  const dao = new Dao(db)
  const collection = dao.findCollectionByNameOrId("3i6w249bum5mm2d")

  // remove
  collection.schema.removeField("7zkiyfod")

  return dao.saveCollection(collection)
})
