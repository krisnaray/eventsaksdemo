
import os
import logging
import traceback
from flask import Flask, request, jsonify
from azure.cosmos import CosmosClient, PartitionKey, exceptions
from dotenv import load_dotenv
from flask_cors import CORS
from azure.identity import DefaultAzureCredential

load_dotenv()


# --- Logging Configuration ---
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
LOG_FORMAT = "%(asctime)s %(levelname)s %(name)s %(message)s"
LOG_FILE = os.getenv("LOG_FILE", "backend_app.log")

logging.basicConfig(
    level=LOG_LEVEL,
    format=LOG_FORMAT,
    handlers=[
        logging.StreamHandler()
    ]
)
logger = logging.getLogger("backend.app")

app = Flask(__name__)

# Global error handler to log stack traces for all unhandled exceptions
@app.errorhandler(Exception)
def handle_exception(e):
    logger.error("Unhandled Exception: %s\n%s", e, traceback.format_exc())
    # Return a generic error message (do not leak details to client)
    return jsonify({"error": "Internal server error"}), 500
CORS(app)  # Enable CORS for all routes

# Cosmos DB configuration
COSMOS_DB_ENDPOINT = os.getenv("COSMOS_DB_ENDPOINT")
DATABASE_NAME = "EventManagement"
CONTAINER_NAME = "Events"

# Initialize Cosmos DB client with managed identity
credential = DefaultAzureCredential()
client = CosmosClient(url=COSMOS_DB_ENDPOINT, credential=credential)
database = client.get_database_client(DATABASE_NAME)
container = database.get_container_client(CONTAINER_NAME)

def ensure_db_container_exists():
    """Ensures the database and container exist, creating them if necessary."""
    try:
        client.create_database_if_not_exists(DATABASE_NAME)
        logger.info(f"Database '{DATABASE_NAME}' ensured.")
        database.create_container_if_not_exists(
            id=CONTAINER_NAME,
            partition_key=PartitionKey(path="/id")
        )
        logger.info(f"Container '{CONTAINER_NAME}' ensured.")
    except exceptions.CosmosHttpResponseError as e:
        logger.error(f"Error ensuring database/container: {e}")
        raise

ensure_db_container_exists()


@app.route("/events", methods=["POST"])
def create_event():
    """Creates a new event."""
    data = request.get_json()
    if not data or not data.get("name") or not data.get("date") or not data.get("description"):
        logger.warning(f"POST /events missing required fields: {data}")
        return jsonify({"error": "Missing required fields: name, date, description"}), 400
    
    # Simple ID generation (consider using UUID in a real app)
    event_id = data.get("id")
    if not event_id:
        # Find the current max id and increment
        query = "SELECT VALUE MAX(c.id) FROM c"
        max_id_result = list(container.query_items(query, enable_cross_partition_query=True))
        current_max_id = 0
        if max_id_result and max_id_result[0] is not None :
            try:
                current_max_id = int(max_id_result[0])
            except (ValueError, TypeError):
                current_max_id = 0 # Fallback if conversion fails or no numeric IDs yet
        
        event_id = str(current_max_id + 1)


    event_item = {
        "id": event_id,
        "name": data["name"],
        "date": data["date"],
        "description": data["description"]
    }
    try:
        created_item = container.create_item(body=event_item)
        return jsonify(created_item), 201
    except exceptions.CosmosResourceExistsError as e:
        logger.info(f"CosmosResourceExistsError (duplicate ID) in create_event: {e}")
        return jsonify({"error": "Event with this ID already exists"}), 409
    except exceptions.CosmosHttpResponseError as e:
        # Cosmos DB 409 Conflict (duplicate ID)
        if hasattr(e, 'status_code') and e.status_code == 409:
            logger.info(f"409 Conflict in create_event: {e}")
            return jsonify({"error": "Event with this ID already exists"}), 409
        # Other Cosmos DB errors
        logger.error(f"5xx Cosmos error in create_event: {e}\n{traceback.format_exc()}")
        return jsonify({"error": "Database error"}), 500
    except Exception as e:
        logger.error(f"500 error in create_event: {e}\n{traceback.format_exc()}")
        return jsonify({"error": "Internal server error"}), 500

@app.route("/events", methods=["GET"])
def get_events():
    """Retrieves all events."""
    try:
        events = list(container.read_all_items())
        return jsonify(events), 200
    except Exception as e:
        import traceback
        logger.error(f"500 error in get_events: {e}\n{traceback.format_exc()}")
        return jsonify({"error": "Internal server error"}), 500

@app.route("/events/<string:event_id>", methods=["GET"])
def get_event(event_id):
    """Retrieves a specific event by its ID."""
    try:
        event_item = container.read_item(item=event_id, partition_key=event_id)
        return jsonify(event_item), 200
    except exceptions.CosmosResourceNotFoundError:
        return jsonify({"error": "Event not found"}), 404
    except Exception as e:
        import traceback
        logger.error(f"500 error in get_event: {e}\n{traceback.format_exc()}")
        return jsonify({"error": "Internal server error"}), 500

@app.route("/events/<string:event_id>", methods=["PUT"])
def update_event(event_id):
    """Updates an existing event."""
    data = request.get_json()
    if not data:
        logger.warning(f"PUT /events/{event_id} missing request body.")
        return jsonify({"error": "Request body is missing"}), 400

    try:
        # Read the existing item
        existing_item = container.read_item(item=event_id, partition_key=event_id)
        # Update fields, maintaining the original ID
        updated_item_data = {
            "id": existing_item["id"], # Ensure the ID is not changed
            "name": data.get("name", existing_item.get("name")),
            "date": data.get("date", existing_item.get("date")),
            "description": data.get("description", existing_item.get("description"))
        }
        updated_item = container.replace_item(item=existing_item, body=updated_item_data)
        return jsonify(updated_item), 200
    except exceptions.CosmosResourceNotFoundError:
        return jsonify({"error": "Event not found"}), 404
    except Exception as e:
        import traceback
        logger.error(f"500 error in update_event: {e}\n{traceback.format_exc()}")
        return jsonify({"error": "Internal server error"}), 500

@app.route("/events/<string:event_id>", methods=["DELETE"])
def delete_event(event_id):
    """Deletes an event."""
    try:
        container.delete_item(item=event_id, partition_key=event_id)
        return "", 204
    except exceptions.CosmosResourceNotFoundError:
        return jsonify({"error": "Event not found"}), 404
    except Exception as e:
        import traceback
        logger.error(f"500 error in delete_event: {e}\n{traceback.format_exc()}")
        return jsonify({"error": "Internal server error"}), 500

if __name__ == "__main__":
    app.run(debug=True)
