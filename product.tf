provider "aws" {
  profile = "default"
  region  = "us-east-2"
}

# Creates DynamoDB database 
resource "aws_dynamodb_table" "product_table" { 
  name         = "PRODUCT"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "product_id"  
  
  attribute {
    name = "product_id"
    type = "S"
  }  
  
  attribute {
    name = "category"
    type = "S"
  }  
  
  attribute {
    name = "product_rating"
    type = "N"
  }  
  
  global_secondary_index {
    name            = "ProductCategoryRatingIndex"
    hash_key        = "category"
    range_key       = "product_rating"
    projection_type = "ALL"
  }
  
  point_in_time_recovery {
    enabled = true
  }
}

# Create API Gateway 
resource "aws_api_gateway_rest_api" "product_apigw" {
  name        = "product_apigw"
  description = "Product API Gateway"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "product" {
  rest_api_id = aws_api_gateway_rest_api.product_apigw.id
  parent_id   = aws_api_gateway_rest_api.product_apigw.root_resource_id
  path_part   = "product"
}

resource "aws_api_gateway_method" "createproduct" {
  rest_api_id   = aws_api_gateway_rest_api.product_apigw.id
  resource_id   = aws_api_gateway_resource.product.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "createproduct-lambda" {
    rest_api_id = aws_api_gateway_rest_api.product_apigw.id
    resource_id = aws_api_gateway_method.createproduct.resource_id
    http_method = aws_api_gateway_method.createproduct.http_method  
    integration_http_method = "POST"
    type                    = "AWS_PROXY"
    uri = aws_lambda_function.CreateProductHandler.invoke_arn
}


# Create lambda and needed permissions 

resource "aws_lambda_permission" "apigw-CreateProductHandler" {  
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.CreateProductHandler.function_name
    principal     = "apigateway.amazonaws.com"  
    source_arn    = "${aws_api_gateway_rest_api.product_apigw.execution_arn}/*/POST/product"
}

resource "aws_api_gateway_deployment" "productapistageprod" {  
    depends_on = [
        aws_api_gateway_integration.createproduct-lambda
    ]

    rest_api_id = aws_api_gateway_rest_api.product_apigw.id
    stage_name  = "prod"
}

resource "aws_iam_role" "ProductLambdaRole" {
  name               = "ProductLambdaRole"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

data "template_file" "productlambdapolicy" {
  template = "${file("${path.module}/policy.json")}"
}

resource "aws_iam_policy" "ProductLambdaPolicy" {
  name        = "ProductLambdaPolicy"
  path        = "/"
  description = "IAM policy for Product lambda functions"
  policy      = data.template_file.productlambdapolicy.rendered
}

resource "aws_iam_role_policy_attachment" "ProductLambdaRolePolicy" {
  role       = aws_iam_role.ProductLambdaRole.name
  policy_arn = aws_iam_policy.ProductLambdaPolicy.arn
}

resource "aws_lambda_function" "CreateProductHandler" { 

    function_name = "CreateProductHandler"  
    filename = "../lambda/productLambda.zip"  
    handler = "createproduct.lambda_handler"
    runtime = "python3.8"  

    environment {
        variables = {
        REGION        = "us-east-2"
        PRODUCT_TABLE = aws_dynamodb_table.product_table.name
    }
  }  
  
    source_code_hash = filebase64sha256("../lambda/productLambda.zip")  
    role = aws_iam_role.ProductLambdaRole.arn
    timeout     = "5"
    memory_size = "128"

  tracing_config {
    mode = "PassThrough"
  }
}

# Create Loadbalancer 
resource "aws_lb" "loadBalancer" {

    name                = "productLoadBalancer"
    internal            = false
    load_balancer_type  = "application"

    access_logs {
      bucket = aws_s3_bucket.productBucket.bucket
      prefix = "log-bucket"
      enabled = true
    }
  drop_invalid_header_fields = true
  enable_deletion_protection = true
}


# Create S3 bucket 
resource "aws_s3_bucket" "productBucket" {

    bucket = "productsBucket"
    acl    = "private"
}

resource "aws_s3_bucket_versioning" "productBucket" {
  bucket = aws_s3_bucket.productBucket.id

  versioning_configuration {
    status = "Enabled"
  }
}