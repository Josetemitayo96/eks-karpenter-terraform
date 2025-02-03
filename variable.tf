variable "AWS_REGION" {
  description = "AWS region"
  type        = string
  default     = "eu-west-1"
}

variable "vpc_id" {
  description = "vpc id"
  type        = string

}

variable "subnet_ids" {
  description = "subnet id"

}

variable "security_group" {
  
}