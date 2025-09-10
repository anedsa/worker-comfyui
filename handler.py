import runpod
from runpod.serverless.utils import rp_upload
import json
import urllib.request
import urllib.parse
import time
import os
import requests
import base64
from io import BytesIO
import websocket
import uuid
import tempfile
import socket
import traceback

# Time to wait between API check attempts in milliseconds
COMFY_API_AVAILABLE_INTERVAL_MS = 50
# Maximum number of API check attempts
COMFY_API_AVAILABLE_MAX_RETRIES = 500
# Websocket reconnection behaviour
WEBSOCKET_RECONNECT_ATTEMPTS = int(os.environ.get("WEBSOCKET_RECONNECT_ATTEMPTS", 5))
WEBSOCKET_RECONNECT_DELAY_S = int(os.environ.get("WEBSOCKET_RECONNECT_DELAY_S", 3))

if os.environ.get("WEBSOCKET_TRACE", "false").lower() == "true":
    websocket.enableTrace(True)

# Host where ComfyUI is running
COMFY_HOST = "127.0.0.1:8188"
# Enforce a clean state after each job is done
REFRESH_WORKER = os.environ.get("REFRESH_WORKER", "false").lower() == "true"


def _comfy_server_status():
    """Return a dictionary with basic reachability info for the ComfyUI HTTP server."""
    try:
        resp = requests.get(f"http://{COMFY_HOST}/", timeout=5)
        return {
            "reachable": resp.status_code == 200,
            "status_code": resp.status_code,
        }
    except Exception as exc:
        return {"reachable": False, "error": str(exc)}


def _attempt_websocket_reconnect(ws_url, max_attempts, delay_s, initial_error):
    """Attempts to reconnect to the WebSocket server after a disconnect."""
    print(
        f"worker-comfyui - Websocket connection closed unexpectedly: {initial_error}. Attempting to reconnect..."
    )
    last_reconnect_error = initial_error
    for attempt in range(max_attempts):
        srv_status = _comfy_server_status()
        if not srv_status["reachable"]:
            print(
                f"worker-comfyui - ComfyUI HTTP unreachable – aborting websocket reconnect: {srv_status.get('error', 'status '+str(srv_status.get('status_code')))}"
            )
            raise websocket.WebSocketConnectionClosedException(
                "ComfyUI HTTP unreachable during websocket reconnect"
            )

        print(
            f"worker-comfyui - Reconnect attempt {attempt + 1}/{max_attempts}... (ComfyUI HTTP reachable, status {srv_status.get('status_code')})"
        )
        try:
            new_ws = websocket.WebSocket()
            new_ws.connect(ws_url, timeout=10)
            print(f"worker-comfyui - Websocket reconnected successfully.")
            return new_ws
        except (
            websocket.WebSocketException,
            ConnectionRefusedError,
            socket.timeout,
            OSError,
        ) as reconn_err:
            last_reconnect_error = reconn_err
            print(
                f"worker-comfyui - Reconnect attempt {attempt + 1} failed: {reconn_err}"
            )
            if attempt < max_attempts - 1:
                print(
                    f"worker-comfyui - Waiting {delay_s} seconds before next attempt..."
                )
                time.sleep(delay_s)
            else:
                print(f"worker-comfyui - Max reconnection attempts reached.")

    print("worker-comfyui - Failed to reconnect websocket after connection closed.")
    raise websocket.WebSocketConnectionClosedException(
        f"Connection closed and failed to reconnect. Last error: {last_reconnect_error}"
    )


def validate_input(job_input):
    """Validates the input for the handler function."""
    if job_input is None:
        return None, "Please provide input"

    if isinstance(job_input, str):
        try:
            job_input = json.loads(job_input)
        except json.JSONDecodeError:
            return None, "Invalid JSON format in input"

    # Validate required inputs
    image = job_input.get("image")
    if not image:
        return None, "Missing 'image' parameter (must be a base64 string)"

    main_prompt = job_input.get("main_prompt")
    if not main_prompt:
        return None, "Missing 'main_prompt' parameter"
        
    # Face prompt is optional
    face_prompt = job_input.get("face_prompt", "") # Default to empty string if not provided

    return {"image": image, "main_prompt": main_prompt, "face_prompt": face_prompt}, None


def check_server(url, retries=500, delay=50):
    """Check if a server is reachable via HTTP GET request."""
    print(f"worker-comfyui - Checking API server at {url}...")
    for i in range(retries):
        try:
            response = requests.get(url, timeout=5)
            if response.status_code == 200:
                print(f"worker-comfyui - API is reachable")
                return True
        except requests.exceptions.RequestException:
            pass
        time.sleep(delay / 1000)
    print(f"worker-comfyui - Failed to connect to server at {url} after {retries} attempts.")
    return False


def upload_image(image_b64, filename="input_face.png"):
    """Uploads a single base64 encoded image to ComfyUI."""
    print(f"worker-comfyui - Uploading image '{filename}'...")
    try:
        # Strip Data URI prefix if present
        if "," in image_b64:
            base64_data = image_b64.split(",", 1)[1]
        else:
            base64_data = image_b64
        
        image_bytes = base64.b64decode(base64_data)
        
        files = {
            "image": (filename, BytesIO(image_bytes), "image/png"),
            "overwrite": (None, "true"),
        }
        
        response = requests.post(f"http://{COMFY_HOST}/upload/image", files=files, timeout=30)
        response.raise_for_status()
        
        print(f"worker-comfyui - Successfully uploaded {filename}")
        return {"status": "success", "filename": filename}
    except Exception as e:
        error_msg = f"Error uploading {filename}: {e}"
        print(f"worker-comfyui - {error_msg}")
        return {"status": "error", "message": error_msg}


def queue_workflow(workflow, client_id):
    """Queue a workflow to be processed by ComfyUI."""
    payload = {"prompt": workflow, "client_id": client_id}
    data = json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    try:
        response = requests.post(f"http://{COMFY_HOST}/prompt", data=data, headers=headers, timeout=30)
        response.raise_for_status()
        return response.json()
    except requests.RequestException as e:
        print(f"worker-comfyui - Error queueing workflow: {e}")
        if e.response:
            print(f"worker-comfyui - Response body: {e.response.text}")
        raise ValueError(f"Error communicating with ComfyUI: {e}")


def get_history(prompt_id):
    """Retrieve the history of a given prompt using its ID."""
    response = requests.get(f"http://{COMFY_HOST}/history/{prompt_id}", timeout=30)
    response.raise_for_status()
    return response.json()


def get_image_data(filename, subfolder, image_type):
    """Fetch image bytes from the ComfyUI /view endpoint."""
    print(f"worker-comfyui - Fetching image data: type={image_type}, subfolder={subfolder}, filename={filename}")
    data = {"filename": filename, "subfolder": subfolder, "type": image_type}
    url_values = urllib.parse.urlencode(data)
    try:
        response = requests.get(f"http://{COMFY_HOST}/view?{url_values}", timeout=60)
        response.raise_for_status()
        print(f"worker-comfyui - Successfully fetched image data for {filename}")
        return response.content
    except requests.RequestException as e:
        print(f"worker-comfyui - Error fetching image data for {filename}: {e}")
        return None


def handler(job):
    """Handles a job using ComfyUI via websockets for status and image retrieval."""
    job_input = job.get("input", {})
    job_id = job.get("id")

    validated_data, error_message = validate_input(job_input)
    if error_message:
        return {"error": error_message}

    image_b64 = validated_data["image"]
    main_prompt = validated_data["main_prompt"]
    face_prompt = validated_data["face_prompt"]

    if not check_server(f"http://{COMFY_HOST}/", COMFY_API_AVAILABLE_MAX_RETRIES, COMFY_API_AVAILABLE_INTERVAL_MS):
        return {"error": f"ComfyUI server ({COMFY_HOST}) not reachable."}

    # Upload the input image
    upload_result = upload_image(image_b64)
    if upload_result["status"] == "error":
        return {"error": "Failed to upload input image", "details": upload_result["message"]}
    
    input_image_filename = upload_result["filename"]

    # Load the workflow from the JSON file
    try:
        with open('workflow_api.json', 'r') as f:
            workflow = json.load(f)
    except FileNotFoundError:
        return {"error": "workflow_api.json not found."}
    except json.JSONDecodeError:
        return {"error": "Failed to parse workflow_api.json."}
        
    # --- Modify the workflow with user inputs ---
    workflow["519"]["inputs"]["prompt"] = main_prompt
    workflow["533"]["inputs"]["prompt"] = face_prompt
    workflow["586"]["inputs"]["image"] = input_image_filename
    # --- End modification ---

    ws = None
    client_id = str(uuid.uuid4())
    prompt_id = None
    output_data = []
    errors = []

    try:
        ws_url = f"ws://{COMFY_HOST}/ws?clientId={client_id}"
        print(f"worker-comfyui - Connecting to websocket: {ws_url}")
        ws = websocket.WebSocket()
        ws.connect(ws_url, timeout=10)
        print(f"worker-comfyui - Websocket connected")
        
        queued_workflow = queue_workflow(workflow, client_id)
        prompt_id = queued_workflow.get("prompt_id")
        if not prompt_id:
            raise ValueError(f"Missing 'prompt_id' in queue response: {queued_workflow}")
        print(f"worker-comfyui - Queued workflow with ID: {prompt_id}")

        print(f"worker-comfyui - Waiting for workflow execution ({prompt_id})...")
        while True:
            try:
                out = ws.recv()
                if isinstance(out, str):
                    message = json.loads(out)
                    if message.get("type") == "executing" and message.get("data", {}).get("node") is None and message.get("data", {}).get("prompt_id") == prompt_id:
                        print(f"worker-comfyui - Execution finished for prompt {prompt_id}")
                        break
                    elif message.get("type") == "execution_error":
                        data = message.get("data", {})
                        if data.get("prompt_id") == prompt_id:
                            error_details = f"Node Type: {data.get('node_type')}, Node ID: {data.get('node_id')}, Message: {data.get('exception_message')}"
                            print(f"worker-comfyui - Execution error received: {error_details}")
                            errors.append(f"Workflow execution error: {error_details}")
                else:
                    continue # Skip binary messages
            except websocket.WebSocketConnectionClosedException as closed_err:
                 ws = _attempt_websocket_reconnect(ws_url, WEBSOCKET_RECONNECT_ATTEMPTS, WEBSOCKET_RECONNECT_DELAY_S, closed_err)
                 continue # Resume listening after successful reconnect


        history = get_history(prompt_id)
        prompt_history = history.get(prompt_id, {})
        outputs = prompt_history.get("outputs", {})

        print(f"worker-comfyui - Processing {len(outputs)} output nodes...")
        for node_id, node_output in outputs.items():
            if "images" in node_output:
                for image_info in node_output["images"]:
                    if image_info.get("type") == "temp":
                        continue
                    
                    filename = image_info.get("filename")
                    image_bytes = get_image_data(filename, image_info.get("subfolder", ""), image_info.get("type"))
                    
                    if image_bytes:
                        if os.environ.get("BUCKET_ENDPOINT_URL"):
                            s3_url = rp_upload.upload_image(job_id, BytesIO(image_bytes))
                            output_data.append({"image": s3_url})
                        else:
                            base64_image = base64.b64encode(image_bytes).decode("utf-8")
                            output_data.append({"image": base64_image})
                    else:
                        errors.append(f"Failed to fetch image data for {filename}")

    except Exception as e:
        print(f"worker-comfyui - Handler Error: {e}")
        print(traceback.format_exc())
        return {"error": f"An unexpected error occurred: {e}"}
    finally:
        if ws and ws.connected:
            ws.close()

    if errors:
        return {"error": "Job failed with errors", "details": errors}
    
    if not output_data:
         return {"status": "success_no_images", "message": "Workflow completed but no output images were generated."}

    return {"images": output_data}


if __name__ == "__main__":
    print("worker-comfyui - Starting handler...")
    runpod.serverless.start({"handler": handler})
