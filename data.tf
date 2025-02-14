data "aws_caller_identity" "source" {
  provider = aws
}

data "aws_caller_identity" "destination" {
  provider = aws.destination
}
