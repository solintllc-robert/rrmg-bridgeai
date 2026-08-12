# ---------------------------------------------------------------------------
# Lambda: the mock customer directory data source
# ---------------------------------------------------------------------------

data "archive_file" "mock_api" {
  type        = "zip"
  source_dir  = "${path.module}/../mock-api/src"
  output_path = "${path.module}/build/mock-api.zip"
}

resource "aws_iam_role" "mock_api" {
  name = "${var.name_prefix}-mock-api-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "mock_api_logs" {
  role       = aws_iam_role.mock_api.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "mock_api" {
  name              = "/aws/lambda/${var.name_prefix}-mock-api"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "mock_api" {
  function_name = "${var.name_prefix}-mock-api"
  role          = aws_iam_role.mock_api.arn
  handler       = "app.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 10
  memory_size   = 256

  filename         = data.archive_file.mock_api.output_path
  source_code_hash = data.archive_file.mock_api.output_base64sha256

  depends_on = [
    aws_iam_role_policy_attachment.mock_api_logs,
    aws_cloudwatch_log_group.mock_api,
  ]
}

# ---------------------------------------------------------------------------
# API Gateway: IAM-authorized REST front end
#
# A single {proxy+} catch-all keeps the infrastructure small; the Lambda does
# the routing. Authorization is AWS_IAM, so callers must present SigV4 -
# ACGW-MCP signs with its own execution role and no API key exists anywhere.
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "mock_api" {
  name        = "${var.name_prefix}-mock-api"
  description = "Mock customer directory API for the bridge.ai proof of concept."

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.mock_api.id
  parent_id   = aws_api_gateway_rest_api.mock_api.root_resource_id
  path_part   = "{proxy+}"
}

resource "aws_api_gateway_method" "proxy" {
  rest_api_id   = aws_api_gateway_rest_api.mock_api.id
  resource_id   = aws_api_gateway_resource.proxy.id
  http_method   = "ANY"
  authorization = "AWS_IAM"

  request_parameters = {
    "method.request.path.proxy" = true
  }
}

resource "aws_api_gateway_integration" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.mock_api.id
  resource_id = aws_api_gateway_resource.proxy.id
  http_method = aws_api_gateway_method.proxy.http_method

  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.mock_api.invoke_arn
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.mock_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.mock_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "mock_api" {
  rest_api_id = aws_api_gateway_rest_api.mock_api.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.proxy.id,
      aws_api_gateway_method.proxy.id,
      aws_api_gateway_integration.proxy.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "mock_api" {
  rest_api_id   = aws_api_gateway_rest_api.mock_api.id
  deployment_id = aws_api_gateway_deployment.mock_api.id
  stage_name    = var.api_stage_name
}
